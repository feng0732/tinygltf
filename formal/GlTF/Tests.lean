/-
  Kernel-checked regression tests for the specification. Every `example` is
  decided by the kernel (`decide`), so a wrong verdict fails `lake build`.
  Each case mirrors a C test in tests/tester_v3_c.c.
-/
import GlTF.Validate
import GlTF.Glb
import GlTF.C.Gen

namespace GlTF.Tests
open Validate

def minimal : Model := {}

example : WellFormedStrict minimal := by decide

/-- tester_v3_c: check_strictness_levels, alphaMode "FOO". -/
def badAlpha : Model := { materials := [{ alphaMode := str "FOO" }] }
example : WellFormedSafe badAlpha := by decide
example : ¬ WellFormedStrict badAlpha := by decide
example : validate {} badAlpha = .ok := by decide
example : validate { strictness := .strict } badAlpha = .invalidValue := by decide

/-- camera type "foo". -/
def badCamera : Model := { cameras := [{ type := str "foo" }] }
example : validate { strictness := .strict } badCamera = .invalidValue := by decide
example : Validate.cameraMask { type := str "foo" } = bit 0 := by decide

/-- primitive mode 99. -/
def badMode : Model := { meshes := [{ primitives := [{ mode := 99 }] }] }
example : validate {} badMode = .ok := by decide
example : validate { strictness := .strict } badMode = .invalidValue := by decide

/-- metallicFactor 2.0 is out of [0,1]; NaN fails every range check. -/
example : materialMask { pbr := { metallicFactor := F64.two } } = bit 2 := by decide
example : materialMask { alphaCutoff := F64.nan } = bit 1 := by decide
example : materialMask {} = 0 := by decide

/-- byteStride 5. -/
example : bufferViewMask { buffer := 0, byteLength := 8, byteStride := 5 } = bit 1 := by decide

/-- extensionsRequired must be a subset of extensionsUsed. -/
example : modelMask { extensionsRequired := [str "EXT_x"] } = bit 0 := by decide
example : modelMask { extensionsRequired := [str "EXT_x"], extensionsUsed := [str "EXT_x"] } = 0 := by
  decide

/-- check_oob_index_rejected: out-of-range bufferView is a memory-safety error
    in every strictness mode. -/
def oobIndex : Model :=
  { buffers := [{ byteLength := 4 }],
    bufferViews := [{ buffer := 0, byteLength := 4 }],
    accessors := [{ bufferView := 1000000, componentType := CT.ubyte, count := 1, type := AT.scalar }] }
example : validate {} oobIndex = .invalidIndex := by decide
example : validate { validateIndices := false } oobIndex = .ok := by decide

/-- check_accessor_range_rejected-style case: 2 VEC3 floats need 24 bytes. -/
def accRange (bvLen : UInt64) : Model :=
  { buffers := [{ byteLength := 64 }],
    bufferViews := [{ buffer := 0, byteLength := bvLen }],
    accessors := [{ bufferView := 0, componentType := CT.float, count := 2, type := AT.vec3 }] }
example : validate {} (accRange 24) = .ok := by decide
example : validate {} (accRange 23) = .invalidAccessor := by decide

/-- Material texture indices are validated (added with tg3_validate). -/
example : validate {} { materials := [{ normalTexture := { index := 7 } }] } = .invalidIndex := by
  decide

/-! ## Attribute / index resource contract (`contractOk`)

These mirror the C tests in `check_attribute_contract`,
`check_morph_target_contract`, `check_index_value_contract` and
`check_contract_accepts_valid_model`. -/

/-- Three VEC3 float vertices in one tightly packed view. -/
def pos3 : Accessor :=
  { bufferView := 0, componentType := CT.float, count := 3, type := AT.vec3 }

def posModel (attrs : List (Bytes × Int32)) (accessors : List Accessor) : Model :=
  { buffers := [{ byteLength := 256 }],
    bufferViews := [{ buffer := 0, byteLength := 36 }],
    accessors := accessors,
    meshes := [{ primitives := [{ attributes := attrs }] }] }

/-- POSITION + NORMAL with matching lengths and shapes is accepted. -/
example : contractOk (posModel [(str "POSITION", 0), (str "NORMAL", 0)] [pos3]) = true := by
  decide

/-- A NORMAL accessor with a different element count is rejected. -/
example : contractOk (posModel [(str "POSITION", 0), (str "NORMAL", 1)]
    [pos3, { pos3 with count := 4 }]) = false := by
  decide

/-- POSITION must be FLOAT VEC3. -/
example : contractOk (posModel [(str "POSITION", 0)]
    [{ pos3 with type := AT.vec2 }]) = false := by
  decide

/-- TANGENT on a base primitive is FLOAT VEC4; on a morph target it is VEC3. -/
example : contractOk (posModel [(str "POSITION", 0), (str "TANGENT", 0)] [pos3]) = false := by
  decide
example : contractOk
    { posModel [(str "POSITION", 0)] [pos3] with
      meshes := [{ primitives := [{ attributes := [(str "POSITION", 0)],
                                    targets := [[(str "POSITION", 0)]] }] }] } = true := by
  decide

/-- Unknown semantics are rejected; "_CUSTOM" is allowed. -/
example : contractOk (posModel [(str "POSITION", 0), (str "FOO", 0)] [pos3]) = false := by
  decide
example : contractOk (posModel [(str "POSITION", 0), (str "_CUSTOM", 0)] [pos3]) = true := by
  decide

/-- An element crossing its stride slot is rejected: offset 8 + VEC3 (12) > 16. -/
example : interleaveOk
    { bufferViews := [{ buffer := 0, byteLength := 72, byteStride := 16 }] }
    { pos3 with byteOffset := 8 } = false := by
  decide
/-- offset 4 + 12 = 16 exactly fills the slot; offset 5 crosses it. -/
example : interleaveOk
    { bufferViews := [{ buffer := 0, byteLength := 72, byteStride := 16 }] }
    { pos3 with byteOffset := 4 } = true := by
  decide
example : interleaveOk
    { bufferViews := [{ buffer := 0, byteLength := 72, byteStride := 16 }] }
    { pos3 with byteOffset := 5 } = false := by
  decide
example : interleaveOk
    { bufferViews := [{ buffer := 0, byteLength := 96, byteStride := 48 }] }
    { pos3 with byteOffset := 12 } = true := by
  decide

/-- Morph targets must keep the base vertex count and match mesh.weights. -/
def targetModel (targetCount : UInt64) (weights : List F64) : Model :=
  { buffers := [{ byteLength := 256 }],
    bufferViews := [{ buffer := 0, byteLength := 36 }],
    accessors := [pos3, { pos3 with count := targetCount }],
    meshes := [{ weights := weights,
                 primitives := [{ attributes := [(str "POSITION", 0)],
                                  targets := [[(str "POSITION", 1)]] }] }] }

example : contractOk (targetModel 3 [F64.half]) = true := by decide +kernel
example : contractOk (targetModel 2 [F64.half]) = false := by decide +kernel
example : contractOk (targetModel 3 []) = true := by decide +kernel
example : contractOk (targetModel 3 [F64.half, F64.half]) = false := by decide +kernel

/-- Index values are read from the loaded bytes; (0,1,5) is out of range for
    three vertices while (0,1,2) is accepted. -/
def idxModel (bytes : List UInt8) : Model :=
  { buffers := [{ byteLength := 44, dataCount := 44, data := bytes }],
    bufferViews := [{ buffer := 0, byteLength := 6 },
                    { buffer := 0, byteOffset := 8, byteLength := 36 }],
    accessors := [{ bufferView := 0, componentType := CT.ushort, count := 3,
                    type := AT.scalar },
                  { bufferView := 1, componentType := CT.float, count := 3, type := AT.vec3 }],
    meshes := [{ primitives := [{ attributes := [(str "POSITION", 1)],
                                  indices := 0 }] }] }

def pad (n : Nat) (xs : List UInt8) : List UInt8 := xs ++ List.replicate n 0

example : contractOk (idxModel (pad 38 [0, 0, 1, 0, 5, 0])) = false := by decide
example : contractOk (idxModel (pad 38 [0, 0, 1, 0, 2, 0])) = true := by decide

/-- An index accessor must be SCALAR and unsigned. -/
example : contractOk
    { idxModel (pad 38 [0, 0, 1, 0, 2, 0]) with
      accessors := [{ bufferView := 0, componentType := CT.float, count := 3,
                      type := AT.scalar }] } = false := by decide

/-- KHR_mesh_quantization widens only the component types of POSITION/NORMAL/
    TANGENT/TEXCOORD_n, and only to normalized signed integers; shapes stay. -/
example : contractOk
    { posModel [(str "POSITION", 0)]
        [{ pos3 with componentType := CT.short, normalized := 1 }] with
      extensionsUsed := [str "KHR_mesh_quantization"] } = true := by decide
/-- ... but not without the extension, and not un-normalized. -/
example : contractOk
    (posModel [(str "POSITION", 0)]
      [{ pos3 with componentType := CT.short, normalized := 1 }]) = false := by decide
example : contractOk
    { posModel [(str "POSITION", 0)] [{ pos3 with componentType := CT.short }] with
      extensionsUsed := [str "KHR_mesh_quantization"] } = false := by decide
/-- ... and it never relaxes the VEC3 shape of POSITION. -/
example : contractOk
    { posModel [(str "POSITION", 0)]
        [{ pos3 with type := AT.vec2, componentType := CT.short, normalized := 1 }] with
      extensionsUsed := [str "KHR_mesh_quantization"] } = false := by decide
/-- ... nor the JOINTS_n rules. -/
example : contractOk
    { posModel [(str "POSITION", 0), (str "JOINTS_0", 1)]
        [pos3, { pos3 with type := AT.vec4, componentType := CT.byte, normalized := 1 }] with
      extensionsUsed := [str "KHR_mesh_quantization"] } = false := by decide

/-! GLB framing -/

deriving instance DecidableEq for Except

def u32le (v : Nat) : List UInt8 :=
  [(v % 256).toUInt8, (v / 2^8 % 256).toUInt8, (v / 2^16 % 256).toUInt8, (v / 2^24 % 256).toUInt8]

def glbV2 (jsonLen : Nat) (declared : Nat) : List UInt8 :=
  [0x67, 0x6C, 0x54, 0x46] ++ u32le 2 ++ u32le (20 + jsonLen) ++
  u32le declared ++ u32le Glb.chunkJSON ++ List.replicate jsonLen 0x20

example : Glb.parseFrame (glbV2 8 8) =
    .ok { jsonOff := 20, jsonLen := 8, hasJson := true } := by decide +kernel
example : Glb.parseFrame (glbV2 8 12) = .error .chunk := by decide +kernel
example : Glb.parseFrame [0x67, 0x6C, 0x54, 0x46, 3, 0, 0, 0, 0, 0, 0, 0] = .error .header := by
  decide
example : Glb.layout 5 0 false = some ({ jsonOff := 20, jsonLen := 8, hasJson := true }, 28) := by
  decide

end GlTF.Tests

/-! MiniC negative controls: the semantics must flag out-of-bounds access. -/
namespace GlTF.Tests.MiniC
open GlTF.C

def isUB {α} : Res α → Bool
  | .ub => true
  | _ => false

def isOkInt {α} (r : Res (Option Val × α)) (n : Nat) : Bool :=
  match r with
  | .ok (some (.int _ k), _) => k == n
  | _ => false

def mem4 : Mem := fun b => if b = 0 then some [0x67, 0x6C, 0x54, 0x46] else none

/-- In bounds: `tg3__rd_u32le(p, 0)` on "glTF" is 0x46546C67. -/
example : isOkInt (callFunc Gen.prog 50 Gen.fid_tg3__rd_u32le [.ptr 0 0, .int IntTy.u64 0] mem4)
    0x46546C67 = true := by decide +kernel

/-- One byte past the end is undefined behaviour, not a silent read. -/
example : isUB (callFunc Gen.prog 50 Gen.fid_tg3__rd_u32le [.ptr 0 0, .int IntTy.u64 1] mem4)
    = true := by decide +kernel

/-- Writing through the frame pointer inside a read-only (expression) call is
    rejected; storing past a too-small frame object is UB. -/
example : isUB (callFunc Gen.prog 200 Gen.fid_tg3__glb_frame_parse
    [.ptr 0 0, .int IntTy.u64 4, .ptr 1 0]
    (fun b => if b = 0 then some [0x67, 0x6C, 0x54, 0x46] else if b = 1 then some (List.replicate 40 0)
      else none)) = true := by decide +kernel

end GlTF.Tests.MiniC
