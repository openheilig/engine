extends RefCounted
## Native actor transforms shared by body and shadow. LGP 0x0816530C /
## 0x080D7934 orientation, 0x080EDE18 support sampling and 0x08161D48 shadow branch.

const CAMERA := Basis(
	Vector3(1.0, -6.928426898866746e-8, -1.3856853797733493e-7),
	Vector3(-1.5492432225983066e-7, -0.44721361994743347, -0.8944272398948669),
	Vector3(0.0, 0.8944272398948669, -0.44721361994743347))
const PROJECTION_X := 0.00374531839042902
const PROJECTION_Y := 0.004999999888241291
## Retained float32 lattice globals 0x089089C0/C4/CC/D0. Not port pixels.
const LATTICE_X := Vector2(0.8944271802902222, 0.4472135901451111)
const LATTICE_Y := Vector2(-0.8944271802902222, 0.4472135901451111)
const CELL_UNITS := 53.66563
const SUPPORT_CORNERS := [Vector2(-48, 0), Vector2(0, -24),
	Vector2(48, 0), Vector2(0, 24)]

enum Branch { NONE, BLOB, PROJECTED, UNKNOWN }


## Captured middle-step 1024x768 camera, expressed in zoom-independent port
## world pixels. XY is source-derived. Z follows the existing terrain slope,
## NOT native depth-buffer parity; no epsilon/visual-fit depth bias is added.
static func retail_to_port() -> Basis:
	var kx := 512.0 * PROJECTION_X
	var ky := 384.0 * PROJECTION_Y
	var slope := -SectorView.DEPTH_STEP / IsoCamera.HH
	return Basis(Vector3(kx * CAMERA.x.x, ky * CAMERA.x.y, slope * ky * CAMERA.x.y),
		Vector3(kx * CAMERA.y.x, ky * CAMERA.y.y, slope * ky * CAMERA.y.y),
		Vector3(kx * CAMERA.z.x, ky * CAMERA.z.y, 0.0))


## Model projection also retains native vertical depth; ground shadows have no
## such component. Shared by rigid objects and animated bodies, never calibrated
## from a humanoid's screenshot height.
static func model_to_port() -> Basis:
	var projection := retail_to_port()
	var depth_scale := projection.y.z / CAMERA.y.z
	projection.z.z = CAMERA.z.z * depth_scale
	return projection


static func lattice_to_native(point: Vector2) -> Vector2:
	# 0x080D620C stores after each complete scalar sum. Vector2 arithmetic
	# would round both products first and rotate a distant actor's heading.
	var screen := Vector2(LATTICE_X.x * point.x + LATTICE_Y.x * point.y,
		LATTICE_X.y * point.x + LATTICE_Y.y * point.y)
	var u := (2.0 / PROJECTION_X) * screen.x / 1024.0
	# 0x080D78FE multiplies by float32 1/768 (0x3AAAAAAB), not a double
	# division. Its rounding changes absolute positions and nearby-point yaw.
	var v := (2.0 / PROJECTION_Y) * screen.y * 0.0013020833721384406
	var determinant := CAMERA.x.x * CAMERA.y.y - CAMERA.x.y * CAMERA.y.x
	return Vector2((CAMERA.y.y * u - CAMERA.y.x * v) / determinant,
		(CAMERA.x.y * u - CAMERA.x.x * v) / determinant)

## Native item angle -> actor+112/+116, 0x081654CE and 0x080D624E.
static func heading_from_degrees(degrees: float) -> Vector2:
	if not is_finite(degrees):
		return Vector2(NAN, NAN)
	var angle := degrees * 0.017453292
	var screen := Vector2(cos(angle), sin(angle))
	var inverse_det := Vector2(1.0 / (LATTICE_Y.y * LATTICE_X.x - LATTICE_Y.x * LATTICE_X.y), 0).x
	return Vector2((screen.x * LATTICE_Y.y - screen.y * LATTICE_Y.x) * inverse_det,
		(screen.y * LATTICE_X.x - screen.x * LATTICE_X.y) * inverse_det)


## The native setter converts two absolute points then subtracts, so preserve
## float32 Vector2 stores rather than substituting body yaw or a direction fit.
static func actor_basis(cell: Vector2, heading: Vector2, model_scale: Vector3) -> Basis:
	var point := Vector2(int(cell.x * CELL_UNITS), int(cell.y * CELL_UNITS))
	var direction := lattice_to_native(point + heading) - lattice_to_native(point)
	if direction.length() < 1.0e-7 or not model_scale.is_finite():
		return Basis(Vector3(NAN, NAN, NAN), Vector3.ZERO, Vector3.ZERO)
	direction = direction.normalized()
	return Basis(Vector3(direction.x, direction.y, 0) * model_scale.x,
		Vector3(-direction.y, direction.x, 0) * -model_scale.y,
		Vector3(0, 0, model_scale.z))


## Native 0x080EDE18 is a four-triangle fan about the mean height, not bilinear.
## `grid` is the selected native support grid; `offset` addresses its cell.
## `base_height` is support record byte51*28 (0 only for no support record).
static func support_height(cell: Vector2, grid: PackedByteArray, offset: int,
		base_height: float) -> float:
	if offset < 0 or offset + Sacred.CELL > grid.size():
		return NAN
	# cPatchPosition stores integer native lattice coordinates.
	var local := Vector2(fmod(float(int(cell.x * CELL_UNITS)), CELL_UNITS),
		fmod(float(int(cell.y * CELL_UNITS)), CELL_UNITS))
	var p := LATTICE_X * local.x + LATTICE_Y * local.y - Vector2(0, 24)
	var heights := Vector4(grid.decode_s8(offset + 24), grid.decode_s8(offset + 25),
		grid.decode_s8(offset + 26), grid.decode_s8(offset + 27)) * 2.5
	var center := (heights.x + heights.y + heights.z + heights.w) * 0.25
	var a: int
	var b: int
	if p.x > 0.0:
		a = 2 if p.y > 0.0 else 1
		b = 3 if p.y > 0.0 else 2
	else:
		a = 3 if p.y > 0.0 else 0
		b = 0 if p.y > 0.0 else 1
	var ca: Vector2 = SUPPORT_CORNERS[a]
	var cb: Vector2 = SUPPORT_CORNERS[b]
	var inverse_det := 1.0 / (ca.x * cb.y - ca.y * cb.x)
	return base_height + center + inverse_det * (p.y * ca.x - ca.y * p.x) * (heights[b] - center) \
		+ (cb.y * p.x - cb.x * p.y) * inverse_det * (heights[a] - center)


## Ordinary single-player actor draw: no debug render override or hidden remote
## player. Those predicates are explicit inputs, not guessed actor flags.
static func branch(type_id: int, items: Sacred.Items, creatures: Sacred.Creatures,
		detail: int, support_ref: int, support_is_horse: bool,
		hidden_remote_player: bool, debug_override: bool) -> Branch:
	if items == null or creatures == null or not items.has_definition(type_id):
		return Branch.UNKNOWN
	if debug_override or hidden_remote_player:
		return Branch.NONE
	var category := items.category_of(type_id)
	if category != 2 and category != 3 and category != 32:
		return Branch.NONE
	# Native draw suppression, not a model-name exception or fitted workaround.
	if type_id == 1249 or (type_id == 71 and detail <= 1):
		return Branch.NONE
	if not creatures.has(type_id):
		return Branch.UNKNOWN
	if creatures.has_flag(type_id, Sacred.Creatures.FLAG_NOSHADOW):
		return Branch.NONE
	if detail != 0 and (support_ref == 0 or support_is_horse):
		return Branch.PROJECTED
	return Branch.BLOB
