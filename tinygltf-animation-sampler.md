# tinygltf 动画采样器：时间输入与输出数量的两条独立契约

动画采样器（`animation.sampler`）把一个 **输入** accessor（关键帧时间）和一个
**输出** accessor（关键帧取值）配对。glTF 2.0 对这两者施加的是**两条相互独立
的契约**：时间轴契约只约束 `input`，长度/类型契约只约束 `output` 与
`input.count`、`interpolation`、目标路径之间的关系。理解二者互不依赖，是在
tinygltf v3 之上做校验或手工构建模型的前提。

本文对应代码：`tiny_gltf_v3.h`（数据结构）、`tiny_gltf_v3.c`（解析与校验）、
`formal/GlTF/Validate.lean`（形式化规范规则）。

---

## 1. 契约一：单调标量时间轴（只约束 `sampler.input`）

glTF 规范对 `sampler.input` 的要求：

- accessor 必须是 **SCALAR / FLOAT**（`TG3_TYPE_SCALAR` +
  `TG3_COMPONENT_TYPE_FLOAT`，见 `tiny_gltf_v3.h:181,197`）；
- 每个元素是以秒为单位的时间，`time[0] >= 0.0`；
- 取值**严格递增**（不允许相等或回退），因此 accessor 必须带 `min`/`max`，
  且 `min[0] >= 0`；
- `input.count >= 1`（实际可用动画至少 2 个关键帧才有插值意义，但规范只要求
  非空）。

关键点：这条契约**不引用输出**。一个 sampler 的输出可以尚未加载、可以是任意
长度，时间轴自身的合法性（标量、浮点、严格递增、非负）都能独立判定。反过来，
输出长度再正确，也无法挽救一个非单调的时间轴。

tinygltf v3 现状：解析器只把 `input`/`output` 存为 accessor 索引
（`tiny_gltf_v3.c:1666-1667`），`validate_indices` 检查索引在
`accessors_count` 范围内（`tiny_gltf_v3.c:1988-1992`），`tg3__spec_animation_mask`
（`tiny_gltf_v3.c:2426`）只检查 `interpolation` 枚举值。**时间单调性、SCALAR/FLOAT
约束、min/max 存在性目前都不在库内校验**，需要消费方自行检查（见第 4 节分级）。

## 2. 契约二：输出长度与类型（约束 `output` × `interpolation` × `path`）

设 `n = input.count`（关键帧数），`m` = 变形目标（morph target）数量。

### 2.1 插值方式对输出长度的影响

| interpolation | `output.count` | 布局 |
|---|---|---|
| `LINEAR`（缺省） | `n`（weights 路径为 `n*m`） | 每帧一个值 |
| `STEP` | `n`（weights 路径为 `n*m`） | 每帧一个值，阶跃保持 |
| `CUBICSPLINE` | `3*n`（weights 路径为 `3*n*m`） | 每帧三元组：内切线、值、外切线 |

**切线三倍长度**：CUBICSPLINE 把每个关键帧展开为
`(in-tangent, value, out-tangent)` 三个连续元素，因此输出元素数恰为关键帧数的
三倍。首帧的内切线与末帧的外切线在求值时会被忽略，但**仍必须存在**——这是
长度契约的一部分，不能省略。`3*n` 不成立（例如 `3*n ± 1`、`n`）即非法。

### 2.2 变形目标数量的影响

仅当通道 `target.path == "weights"` 时，输出还乘以变形目标数 `m`：

- `m` 取自目标 mesh 的 `mesh.primitives[i].targets` 数组长度
  （`tg3_mesh_primitive.targets_count`，`tiny_gltf_v3.h:627-630`），通常也等于
  `mesh.weights_count` / `node.weights_count`；
- 每个关键帧按目标顺序排列 `m` 个权重，即输出是"帧优先"的扁平数组：
  `frame0[target0..targetM-1], frame1[target0..], ...`；
- CUBICSPLINE 下每个权重同样展开为切线三元组，故为 `3*n*m`。

`m = 0`（mesh 无 morph target）时 weights 通道无意义，输出长度应为 0——但
accessor `count >= 1`，所以实际上 weights 通道指向无 morph 的 mesh 即非法。

### 2.3 按路径区分的输出类型

| `target.path` | output accessor `type` | `componentType` | 每帧元素数（LINEAR/STEP） |
|---|---|---|---|
| `translation` | `VEC3` | FLOAT | `n` 个 vec3 |
| `rotation` | `VEC4` | FLOAT（或归一化 BYTE/SHORT，见下） | `n` 个四元数 |
| `scale` | `VEC3` | FLOAT | `n` 个 vec3 |
| `weights` | `SCALAR` | FLOAT（或归一化整型） | `n*m` 个标量 |
| `pointer`（KHR_animation_pointer） | 由被指向属性决定 | — | — |

- 平移/缩放是 `VEC3`，旋转是 `VEC4` 单位四元数——**两者不可混用**；
  把 rotation 输出写成 VEC3 或把 translation 写成 VEC4 都违反契约。
- 规范允许 rotation/weights 使用归一化的 `BYTE`/`UNSIGNED_BYTE`/`SHORT`/
  `UNSIGNED_SHORT` 量化存储（对应 `accessor.normalized = 1`），translation/scale
  必须是 FLOAT。tinygltf 的 `normalized` 字段见 `tiny_gltf_v3.h:523`。
- CUBICSPLINE 下切线与值同型：VEC3 路径的切线也是 VEC3，四元数路径的切线
  也是 VEC4。

注意 tinygltf 的枚举校验只覆盖 `path ∈ {translation, rotation, scale, weights,
pointer}`（`tiny_gltf_v3.c:2431-2437`）和 `interpolation ∈ {LINEAR, STEP,
CUBICSPLINE}`（`tiny_gltf_v3.c:2439-2444`），**输出 accessor 的 type/count 与
路径、插值方式的交叉一致性不在库内校验**。

## 3. 为什么两条契约必须独立判定

- 时间轴单调性需要**读取 buffer 数据**（浮点序列），而长度/类型契约只需要
  **accessor 元数据**（`count`、`type`、`componentType`）。buffer 未加载时后者
  完全可判，前者不可判。
- 长度契约的违反（如 CUBICSPLINE 输出不是 `3*n`）是结构性错误，消费方按
  错误长度解读会直接越界读；时间轴非单调则是语义错误，通常导致插值结果
  异常而非崩溃。两者的严重性与检测成本都不同，不应混为一个"动画合法"谓词。

## 4. 分级校验：buffer 未加载与手工构建模型

建议把校验分为两级，与 tinygltf 现有的 `TG3_PERMISSIVE` / `TG3_STRICT`
（`tiny_gltf_v3.h:277-280`）正交组合：

### Level 0 — 结构级（无需 buffer 数据，解析后即可执行）

1. `sampler.input` / `sampler.output` 索引在范围内（库已做，
   `validate_indices`）；
2. `interpolation` ∈ {LINEAR, STEP, CUBICSPLINE}（库已做，spec 规则）；
3. input accessor：`type == SCALAR`、`componentType == FLOAT`、
   `min/max` 存在且 `min[0] >= 0`；
4. output accessor `type` 与通道 `path` 匹配（VEC3/VEC4/VEC3/SCALAR）；
5. 长度关系：
   - LINEAR/STEP：`output.count == n`（weights：`n*m`）；
   - CUBICSPLINE：`output.count == 3*n`（weights：`3*n*m`）；
6. weights 通道的目标 mesh 确有 `m >= 1` 个 morph target。

### Level 1 — 数据级（需要 buffer 字节已加载）

1. 时间序列严格递增：`t[i] < t[i+1]`，且全部有限；
2. `accessor.min/max` 与实际数据一致（规范要求，多数运行时可容忍偏差）；
3. rotation 关键帧四元数近似归一（容差内）；
4. CUBICSPLINE 切线值有限（NaN 切线会污染整段样条）。

**buffer 尚未加载**（例如只用 `tg3_parse` 读 JSON 骨架、外部 `.bin` 延迟加载，
或 `images_as_is` 式的流式场景）时：Level 0 全部可执行，Level 1 整体跳过或
降级为"待数据到达后再验"。**不要因为拿不到字节就放弃 Level 0**——长度契约
恰好在元数据层面。

**手工构建模型**（用 `tg3_writer_add_animation` 等写出，或程序内拼装
`tg3_model`）时，writer 不做任何交叉校验（`tiny_gltf_v3.c:4248` 是简单序列化），
建议：

- **宽松（PERMISSIVE）**：违反 Level 0/1 规则记 `TG3_SEVERITY_WARNING`，模型
  仍可使用——适合编辑器中间态、调试导出；
- **严格（STRICT）**：违反即 `TG3_SEVERITY_ERROR`，拒绝导出/加载——适合发布
  管线。这与 `tg3__validate_spec` 的分级语义一致
  （`tiny_gltf_v3.c:2533-2536`：PERMISSIVE 下为 warning，STRICT 下解析失败）。

## 5. 合法与非法样例

以下均设 `n = input.count`，`m` = 目标 mesh 的 morph target 数。

### 合法

```jsonc
// LINEAR 平移：input n=2，output 2 个 VEC3
{ "samplers": [{ "input": 0, "output": 1, "interpolation": "LINEAR" }],
  "channels": [{ "sampler": 0, "target": { "node": 0, "path": "translation" } }] }
// accessors[0]: SCALAR/FLOAT count=2, min=[0.0], max=[1.5]  ✓
// accessors[1]: VEC3/FLOAT  count=2                          ✓ (2 == n)
```

```jsonc
// CUBICSPLINE 旋转：input n=3，output 9 个 VEC4（3*3）
// accessors[out]: VEC4/FLOAT count=9  ✓ (3*n，每帧 in-tangent/value/out-tangent)
```

```jsonc
// STEP 权重：n=4，m=2，output 8 个 SCALAR
// accessors[out]: SCALAR/FLOAT count=8  ✓ (n*m，帧优先扁平排列)
```

### 非法

```jsonc
// ✗ 违反长度契约：CUBICSPLINE 但 output.count == n（漏了切线）
//   应为 3*n；消费方按三元组读取会越界。

// ✗ 违反长度契约：weights 通道 output.count == n（漏乘 m）
//   应为 n*m（CUBICSPLINE 时 3*n*m）。

// ✗ 违反类型契约：path="rotation" 但 output 是 VEC3
//   四元数必须是 VEC4；path="translation"/"scale" 必须是 VEC3。

// ✗ 违反时间契约：input 是 VEC3 或整型 componentType
//   时间轴必须是 SCALAR/FLOAT。

// ✗ 违反时间契约：时间序列 [0.0, 0.5, 0.5, 1.0]（非严格递增）
//   或 min 缺失 / min[0] < 0。注意：此条只能在 buffer 数据可用时判定。

// ✗ 结构性：input/output 索引越界（tinygltf validate_indices 已拒绝，
//   与宽松/严格无关，永远是错误）。
```

## 6. 小结

- **输入契约**：SCALAR/FLOAT、非负、严格递增的单调时间轴；判定单调性需要
  buffer 数据，判定类型/边界只需元数据。
- **输出契约**：长度 = `n`（LINEAR/STEP）或 `3*n`（CUBICSPLINE），weights 路径
  再乘 morph target 数 `m`；类型由路径决定（translation/scale→VEC3，
  rotation→VEC4，weights→SCALAR）。
- 两条契约独立成立、独立检测：长度/类型在 buffer 未加载时即可校验，单调性
  必须等数据到达。tinygltf v3 目前只覆盖索引范围与枚举值，交叉一致性校验
  应按 Level 0/Level 1 分级实现，并映射到 PERMISSIVE（warning）/ STRICT
  （error）两档。
