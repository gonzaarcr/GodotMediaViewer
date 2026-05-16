## Vertical scroll index rail: draws section ticks + current-position thumb,
## emits seek_requested(0..1) on click/drag. Pure presentation — owner supplies
## the landmark list and current label.
class_name ScrollNavRail
extends Control

signal seek_requested(pos: float)

const PAD_Y: float = 8.0
const COLLAPSED_W: float = 18.0
const EXPANDED_W: float = 96.0
const PROXIMITY_PX: float = 64.0    # mouse distance from left edge that triggers expand
const EXPAND_SPEED: float = 9.0     # lerp speed (higher = snappier)
const MINOR_TICK_LEN: float = 6.0
const MAJOR_TICK_LEN: float = 12.0
const THUMB_HALF_H: float = 5.0
const SNAP_PX: float = 6.0

var landmarks: Array = []           # [{pos: float, label: String, major: bool}, ...]
var progress: float = 0.0
var current_label: String = ""

var _dragging: bool = false
var _expand: float = 0.0            # 0 = collapsed, 1 = fully expanded
var _font: Font
var _font_size: int = 10


func _ready() -> void:
	_font = get_theme_default_font()
	_font_size = maxi(9, get_theme_default_font_size() - 2)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	offset_left = -COLLAPSED_W
	set_process(true)


func _process(delta: float) -> void:
	# Expand when the mouse approaches the rail's left edge, or while dragging.
	var target := 0.0
	if _dragging:
		target = 1.0
	else:
		var mp := get_global_mouse_position()
		var rect := get_global_rect()
		var dx := 0.0
		if mp.x < rect.position.x:
			dx = rect.position.x - mp.x
		elif mp.x > rect.end.x:
			dx = mp.x - rect.end.x
		var dy := 0.0
		if mp.y < rect.position.y:
			dy = rect.position.y - mp.y
		elif mp.y > rect.end.y:
			dy = mp.y - rect.end.y
		var dist := maxf(dx, dy)
		target = clampf(1.0 - dist / PROXIMITY_PX, 0.0, 1.0)
	var next := lerpf(_expand, target, clampf(delta * EXPAND_SPEED, 0.0, 1.0))
	if absf(next - _expand) > 0.001:
		_expand = next
		offset_left = -lerpf(COLLAPSED_W, EXPANDED_W, _expand)
		queue_redraw()


func set_landmarks(list: Array) -> void:
	landmarks = list
	queue_redraw()


func set_progress(p: float) -> void:
	var clamped := clampf(p, 0.0, 1.0)
	if is_equal_approx(clamped, progress):
		return
	progress = clamped
	queue_redraw()


func set_current_label(text: String) -> void:
	if text == current_label:
		return
	current_label = text
	queue_redraw()


func _usable_height() -> float:
	return maxf(0.0, size.y - 2.0 * PAD_Y)


func _y_for_pos(p: float) -> float:
	return PAD_Y + clampf(p, 0.0, 1.0) * _usable_height()


func _pos_for_y(y: float) -> float:
	var usable := _usable_height()
	if usable <= 0.0:
		return 0.0
	return clampf((y - PAD_Y) / usable, 0.0, 1.0)


func _draw() -> void:
	# Rail hugs our right edge; labels grow leftward into the (expanded) body.
	var rail_x := size.x - COLLAPSED_W * 0.5
	var label_right_x := rail_x - 8.0
	var rail_color := Color(1, 1, 1, 0.22)
	var tick_color := Color(1, 1, 1, 0.4)
	var major_color := Color(1, 1, 1, 0.7)
	var thumb_color := Color(0.95, 0.85, 0.35, 0.95)
	var label_color := Color(1, 1, 1, 0.8 * _expand)
	var thumb_label_color := Color(0.1, 0.1, 0.1, _expand)
	var thumb_label_bg := Color(0.95, 0.85, 0.35, 0.95 * _expand)

	var top_y := PAD_Y
	var bot_y := size.y - PAD_Y
	draw_line(Vector2(rail_x, top_y), Vector2(rail_x, bot_y), rail_color, 2.0)

	for lm in landmarks:
		var y := _y_for_pos(lm["pos"])
		var major: bool = lm.get("major", false)
		var tlen: float = MAJOR_TICK_LEN if major else MINOR_TICK_LEN
		var tcolor: Color = major_color if major else tick_color
		draw_line(Vector2(rail_x - tlen * 0.5, y), Vector2(rail_x + tlen * 0.5, y), tcolor, 1.0)
		var label_text: String = lm.get("label", "")
		if major and label_text != "" and _expand > 0.05:
			var ascent := _font.get_ascent(_font_size)
			var tw: float = _font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
			draw_string(_font, Vector2(label_right_x - tw, y + ascent * 0.35),
				label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, label_color)

	var ty := _y_for_pos(progress)
	draw_rect(Rect2(Vector2(rail_x - 7.0, ty - THUMB_HALF_H),
		Vector2(14.0, THUMB_HALF_H * 2.0)), thumb_color)

	if current_label != "" and _expand > 0.05:
		var ascent2 := _font.get_ascent(_font_size)
		var descent := _font.get_descent(_font_size)
		var tw2: float = _font.get_string_size(current_label, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
		var bg_rect := Rect2(
			Vector2(label_right_x - tw2 - 3.0, ty - ascent2 * 0.6 - 2.0),
			Vector2(tw2 + 6.0, ascent2 + descent + 2.0))
		draw_rect(bg_rect, thumb_label_bg)
		draw_string(_font, Vector2(label_right_x - tw2, ty + ascent2 * 0.35),
			current_label, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, thumb_label_color)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_seek_to_event_y(event.position.y)
			else:
				_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		_seek_to_event_y(event.position.y)


func _seek_to_event_y(y: float) -> void:
	var pos := _pos_for_y(y)
	# Snap to nearest landmark if within SNAP_PX.
	if not landmarks.is_empty():
		var target_y := _y_for_pos(pos)
		var best_dy := SNAP_PX + 1.0
		var best_pos := pos
		for lm in landmarks:
			var ly := _y_for_pos(lm["pos"])
			var dy := absf(ly - target_y)
			if dy < best_dy:
				best_dy = dy
				best_pos = lm["pos"]
		if best_dy <= SNAP_PX:
			pos = best_pos
	seek_requested.emit(pos)
