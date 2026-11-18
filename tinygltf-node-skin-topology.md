# tinygltf v3 (C) 节点图拓扑与蒙皮关节分析

日期：2026-11-18 · 分支：task/55 · 范围：`tiny_gltf_v3.h`、`tiny_gltf_v3.c`、`tinygltf_json_c.h`、`tests/`、`formal/README.md`

## 0. 问题陈述

glTF 的节点图按规范应是一个**森林**（若干不相交的树）：每个节点至多一个父节点、无环；
`scene.nodes` 列出各树的根。蒙皮（skin）的关节世界变换沿父链累积到骨架根（`skin.skeleton`，
缺省时解析到场景根），且带蒙皮网格节点自身的变换按规范应被忽略。
一旦文件中出现**环**或**多父引用**：

- 世界变换沿父链的累积变成无限递归（环）或多值歧义（多父）；
- 关节的世界变换取决于走哪条父链，蒙皮矩阵随之不确定；
- `skin.skeleton` 是否真是所有 joints 的公共祖先、joints 是否都在当前场景内，都失去保证。

本报告确认 tinygltf v3 C 主线条在哪些入口能判定这些关系、目前实际判定到什么程度。

## 1. 阅读范围（代码证据位置）

| 主题 | 位置 |
|---|---|
| 节点解析 | `tiny_gltf_v3.c:1587` `tg3__parse_node`（children 仅作 int 数组读入） |
| 蒙皮解析 | `tiny_gltf_v3.c:1613` `tg3__parse_skin`（joints/skeleton 仅作索引读入） |
| 场景解析 | `tiny_gltf_v3.c:1710` `tg3__parse_scene`（scene.nodes 仅作 int 数组读入） |
| 索引校验 | `tiny_gltf_v3.c:1857` `tg3__validate_indices`（节点 1937–1949、蒙皮 1961–1975、场景 1996–2009） |
| 规范规则校验 | `tiny_gltf_v3.c:2537` `tg3__validate_spec`；skin 规则仅 `tg3__spec_skin_mask`（2411：joints 非空） |
| 校验总入口 | `tiny_gltf_v3.c:2571` `tg3__validate_model`；公开 API `tg3_validate`（2585） |
| 流式回调宏 | `tiny_gltf_v3.c:1793` `TG3__STREAM_CB` |
| 解析主流程 | `tiny_gltf_v3.c:2598` `tg3__parse_from_json` |
| 流式回调类型 | `tiny_gltf_v3.h:928–969` `tg3_stream_callbacks` |
| 解析选项默认值 | `tiny_gltf_v3.c:350` `tg3_parse_options_init` |

## 2. 场景根与关节祖先关系在哪个入口可判定

判定"场景根"需要 `scenes[].nodes` + 全量 `nodes[].children`；判定"关节祖先"还需要
`skins[].joints` / `skins[].skeleton`。三类数据在 `tg3__parse_from_json` 中就绪的时间点不同：

```
on_asset → buffers → … → nodes 解析完 → on_node 回调（2627–2628）
         → … → skins 解析完 → on_skin 回调（2637–2638）
         → animations → cameras → scenes 解析完 → on_scene 回调（2643–2648）
         → tg3__validate_model（2664–2666）   ← 索引/范围/规范校验在这里才运行
         → tg3_parse* 返回
```

由此得到三个候选入口，结论各不相同：

1. **`on_node` / `on_skin` 流式回调：不可判定。** `on_node` 触发时 skins、scenes 尚未解析，
   回调内无法知道该节点是不是 joint、是不是根；`on_skin` 触发时 scenes 尚未解析，
   无法比对 skeleton 根与场景根。
2. **`on_scene` 流式回调：数据最早齐备、但尚不可信的入口。** 这是流式路径中第一个能同时
   看到 nodes+skins+scenes 全量拓扑数据的点，调用方理论上可以在此构建父表并判定根与
   关节祖先；但 `tg3__validate_model` 在所有流式回调**之后**才运行，此刻 children/joints/
   scene.nodes 里的索引可能越界，先建父表等于先解引用未验证的攻击者可控索引。
3. **`tg3_parse*` 返回 `TG3_OK` 之后（或显式调用 `tg3_validate()`）：数据可信的最早入口。**
   默认 `validate_indices=1` 保证所有拓扑相关索引在界内。但注意：**库本身在任何入口都不做
   拓扑判定**——没有父指针表、没有环/多父检测、没有世界变换或蒙皮矩阵计算（公开 API 中
   不存在此类函数，见 `tiny_gltf_v3.h` Section 13 全部导出列表）。判定只能由调用方在
   parse 返回后自行完成。

一句话：**数据就绪的最早入口是 `on_scene`，数据可信的最早入口是 parse 返回之后；
库现有代码没有任何入口实际执行场景根/关节祖先判定。**

## 3. 已证实行为（有直接代码证据）

1. **解析层零拓扑处理。** `tg3__parse_node`/`tg3__parse_skin`/`tg3__parse_scene` 把
   children、joints、scene.nodes 原样存为 `int32_t` 数组，不去重、不建父表、不检查自引用。
2. **校验层只有索引范围检查。** `tg3__validate_indices` 对 `nodes[i].children[k]`、
   `skins[i].joints[k]`、`skins[i].skeleton`、`scenes[i].nodes[k]` 仅做
   `[0, nodes_count)` 范围检查（`TG3__CHECK_REQ/OPT`），错误上限 `TG3__IDX_ERR_CAP = 64`。
   无环检测、无多父检测、无"场景根不相交"检测、无"joint 可达性"检测。
3. **规范规则层无节点拓扑规则。** `tg3__validate_spec` 对 skin 只查 joints 非空
   （`TG3__R_SKIN_NO_JOINTS`），对 model 只查 extensionsRequired ⊆ extensionsUsed；
   没有针对 node/scene 的 spec 规则表（`tg3__msgs_node` 不存在）。
4. **校验严格晚于全部流式回调。** `tg3__validate_model` 在 `tg3__parse_from_json` 末尾
   （2664）运行，而 `on_scene` 在 2648。流式消费方拿到的永远是未校验数据。
5. **流式回调只响应 ABORT。** `TG3__STREAM_CB` 宏只处理 `TG3_STREAM_ABORT`；
   `TG3_STREAM_SKIP` 在解析路径中无任何效果（头文件定义了枚举但 .c 中无消费点）。
6. **默认配置偏安全但不覆盖拓扑。** `tg3_parse_options_init`：strictness=PERMISSIVE、
   validate_indices=1、validate_ranges=1。spec 违规在 PERMISSIVE 下只产生 warning。
7. **库不计算任何变换。** 全库无矩阵乘法/世界变换/蒙皮矩阵代码；`tg3_node` 只存
   TRS+matrix 原始值。环与多父的语义后果完全落在调用方的遍历代码上。
8. **形式化验证不覆盖拓扑。** `formal/` 的已验证核心限于 GLB 帧解析、字节读写、
   `component_size`/`num_components`/base64 及 `buffer_mask`/`skin_mask` 等纯函数；
   节点图遍历不在 MiniC 建模范围内。
9. **测试无拓扑类夹具。** `tests/v3/security/` 仅 4 个文件（negstride、oob_buffer_view、
   oob_extension_indices、traversal_relative），均与节点图无关；fuzzer 无节点拓扑专项。

## 4. 尚未取得证据的风险

以下风险从"库不做防护 + 规范要求森林"推出，但**当前代码库内没有测试或运行证据**证实其
实际触发路径与后果，列为待验证：

1. **环导致调用方无限递归/栈溢出。** 库自身不遍历节点图，所以环不会卡在库内；风险转移给
   消费方的递归遍历。`TINYGLTF3_MAX_NESTING_DEPTH=512` 只限制 JSON 文本嵌套深度，
   对节点图环毫无作用（环是索引层面的，JSON 文本可以很浅）。未验证：典型下游
   （如本仓库 web demo、benchmark）是否有防护。
2. **多父导致世界变换歧义。** 同一节点出现在两个 `children` 数组、或同时出现在
   `scene.nodes` 与他人 `children` 中时，世界变换取决于遍历起点。库不检测，解析照常成功，
   渲染结果静默错误。未验证：现有测试套件是否含此类文件（据检索没有）。
3. **关节祖先关系失真。** `skin.skeleton` 不是 joints 公共祖先、joints 分散在多棵树、
   joint 不在任何场景内、joint 同时是另一 joint 的后代形成关节环——这些都会让蒙皮矩阵
   无定义或重复计算，库均不检查。未验证：fuzzer 长期运行是否曾构造出此类输入并暴露问题。
4. **流式消费方基于未校验索引建父表。** 第 2 节入口 2 的误用模式（在 `on_scene` 里直接
   用 children 索引数组下标）可能造成越界读。库文档未明确警告此时序，属于文档级风险。
5. **`TG3_STREAM_SKIP` 的沉默无效。** 调用方若以为返回 SKIP 能跳过某节点/蒙皮的后续处理，
   实际不会发生任何事，可能据此写出有逻辑漏洞的过滤代码。

## 5. 延迟校验边界

库把校验分为三层，拓扑整体落在边界之外：

| 层 | 内容 | 默认 | 拓扑是否覆盖 |
|---|---|---|---|
| 解析即校验 | JSON 类型、必填字段、数值有限性 | 总是 | 否 |
| `validate_indices` / `validate_ranges` | 索引越界、字节范围、组件类型 | 开 | 仅"索引在界内"，不含图结构 |
| `tg3__validate_spec`（STRICT 升级为错误） | 枚举值、非空数组、因子范围等 | PERMISSIVE 下仅警告 | 否（无节点拓扑规则） |
| **完全推给调用方** | 环、多父、根集合不相交、关节祖先、世界变换语义、蒙皮矩阵 | — | 全部 |

`tg3_validate()`（`tiny_gltf_v3.c:2585`）是显式的延迟校验入口，但它复用同一套
`tg3__validate_model`，同样不含拓扑检查——"延迟校验"目前延迟到的终点仍然是没有拓扑校验。

## 6. 宽松处理 vs 严格处理的兼容代价

**宽松（现状）**：接受任意索引图，解析 O(N)、零额外内存、流式友好。
- 兼容收益：与所有导出器（包括产出非规范文件的）互操作；不会因新增拒绝而打破存量调用方；
  调用方可按自己的遍历策略（如按 scene 根 DFS 并自带 visited 集）自然免疫环与多父。
- 代价：安全边界外移。每个消费方都要自行防环（visited 位图）与防多父（父计数），
  遗漏一处就是栈溢出或静默渲染错误；流式路径尤其容易在第 2 节入口 2 误用未校验索引。

**严格（假设新增拓扑校验，如在 `tg3__validate_model` 内做迭代式 DFS + 父计数位图）**：
- 实现代价：O(N) 时间与 O(N) 位图内存（arena 分配，与现有内存预算机制兼容）；
  规则本身简单（父计数 >1 报错；DFS 灰标记判环；scene 根集合与 children 集合的包含关系）。
- 兼容代价：
  - 任何现存依赖"非法拓扑也能解析成功"的调用方会被打破——若默认开启属于**行为破坏**，
    需要新的 opt-in 选项（如 `validate_topology`，默认 0）或在 STRICT 模式下才启用；
  - PERMISSIVE 下应降级为 warning，与现有 spec 违规处理一致；
  - 若纳入 formal/ 已验证核心，需为 DFS/位图重新做 MiniC 建模与精化证明，工作量显著
    （当前验证核心刻意只含纯函数）；更现实的路径是把它留在验证核心之外；
  - 流式时序不变（校验仍在回调之后），对依赖 `on_scene` 建父表的调用方无额外保护，
    文档需同步说明。
- 收益：把"森林不变量"从每个消费方收拢到库内单点；fuzzer/安全面直接受益；
  蒙皮消费方可以安全地假设关节祖先链有限且唯一。

**建议的折中**：保持默认宽松（兼容现状），新增 opt-in 拓扑校验标志 + STRICT 自动启用，
并在 `tg3_stream_callbacks` 文档中明确"回调触发时索引尚未校验"的时序事实。这样既不给
存量调用方制造破坏，也把第 4 节的四类风险变成可关闭的显式选择。
