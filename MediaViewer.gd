## Full-screen media viewer with zoom, rotation, pan, and video playback.
##
## Keyboard shortcuts
##   Esc          → back to gallery
##   ← / →  or  A / D   → prev / next file
##   + / -        → zoom in / out  (also Ctrl+scroll)
##   Scroll wheel → zoom
##   0            → actual size (1:1 pixels)
##   F            → fit to screen
##   Q            → rotate 90° counter-clockwise
##   E  or  R     → rotate 90° clockwise
##   Space        → play / pause video
##
## Touchpad gestures
##   Pinch        → zoom toward fingers
##   Two-finger scroll → pan  (also pans when zoomed with regular scroll)
extends Control

signal back_pressed

const IMAGE_EXT  := ["png", "jpg", "jpeg", "bmp", "webp", "tga", "svg"]
const VIDEO_EXT  := ["mp4", "webm", "ogv", "avi", "mkv", "mov"]
const ZOOM_MIN   := 0.05
const ZOOM_MAX   := 32.0
const ZOOM_STEP  := 0.12   # fractional factor per scroll tick

# Transform state
var _zoom       := 1.0
var _rot_deg    := 0.0
var _pan        := Vector2.ZERO
var _img_size   := Vector2.ZERO  # natural pixel dimensions (for 1:1 calc)

# File list
var _files   : Array  = []
var _idx     : int    = 0
var _is_video: bool   = false

# UI nodes
var _img_rect   : TextureRect
var _vid_player : VideoStreamPlayer
var _zoom_lbl    : Label
var _file_lbl    : Label
var _nav_lbl     : Label
var _play_btn    : Button
var _vid_bar     : Control
var _seek_bar    : HSlider
var _time_lbl    : Label
var _error_label : Label

# Drag state
var _dragging          := false
var _drag_pan_start    := Vector2.ZERO
var _drag_mouse_start  := Vector2.ZERO

# Content anchor – receives all transforms
var _anchor: Control


# ──────────────────────────── Setup ────────────────────────────────

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	# Dark background
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color("#0e0e0e")
	add_child(bg)

	# Clip region for content
	var clip := Control.new()
	clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	clip.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(clip)

	# Content anchor – manually positioned/scaled/rotated
	_anchor = Control.new()
	_anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(_anchor)

	_img_rect = TextureRect.new()
	_img_rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	_img_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_img_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor.add_child(_img_rect)

	_vid_player = VideoStreamPlayer.new()
	_vid_player.expand  = true
	_vid_player.visible = false
	_vid_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vid_player.finished.connect(_on_video_finished)
	_anchor.add_child(_vid_player)

	# UI overlay (not transformed)
	var ui := Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ui)

	_build_top_bar(ui)
	_build_bottom_bar(ui)

	_error_label = Label.new()
	_error_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.visible = false
	_error_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_error_label)


func _build_top_bar(parent: Control) -> void:
	var bar := PanelContainer.new()
	bar.anchor_right  = 1.0
	bar.anchor_bottom = 0.0
	bar.custom_minimum_size.y = 50
	bar.mouse_filter  = Control.MOUSE_FILTER_STOP
	parent.add_child(bar)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	bar.add_child(hbox)

	_pad(hbox, 6)

	var back := Button.new()
	back.text = "← Back"
	back.tooltip_text = "Back to gallery (Esc)"
	back.pressed.connect(_go_back)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(back)

	hbox.add_child(VSeparator.new())

	_file_lbl = Label.new()
	_file_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_file_lbl.clip_text = true
	_file_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(_file_lbl)

	_nav_lbl = Label.new()
	_nav_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_nav_lbl.custom_minimum_size.x = 60
	_nav_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(_nav_lbl)

	hbox.add_child(VSeparator.new())

	_zoom_lbl = Label.new()
	_zoom_lbl.text = "100%"
	_zoom_lbl.custom_minimum_size.x = 55
	_zoom_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(_zoom_lbl)

	var fit_btn := Button.new()
	fit_btn.text = "Fit"
	fit_btn.tooltip_text = "Fit to screen (F)"
	fit_btn.pressed.connect(_do_fit)
	fit_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(fit_btn)

	var actual_btn := Button.new()
	actual_btn.text = "1:1"
	actual_btn.tooltip_text = "Actual size (0)"
	actual_btn.pressed.connect(_do_actual_size)
	actual_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(actual_btn)

	hbox.add_child(VSeparator.new())

	var rot_l := Button.new()
	rot_l.text = "↺"
	rot_l.tooltip_text = "Rotate 90° left (Q)"
	rot_l.pressed.connect(func() -> void: _rotate_by(-90.0))
	rot_l.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(rot_l)

	var rot_r := Button.new()
	rot_r.text = "↻"
	rot_r.tooltip_text = "Rotate 90° right (E)"
	rot_r.pressed.connect(func() -> void: _rotate_by(90.0))
	rot_r.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(rot_r)

	_pad(hbox, 6)


func _build_bottom_bar(parent: Control) -> void:
	var bar := PanelContainer.new()
	bar.anchor_top    = 1.0
	bar.anchor_bottom = 1.0
	bar.anchor_right  = 1.0
	bar.offset_top    = -50
	bar.custom_minimum_size.y = 50
	bar.mouse_filter  = Control.MOUSE_FILTER_STOP
	parent.add_child(bar)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	bar.add_child(hbox)

	_pad(hbox, 6)

	var prev_btn := Button.new()
	prev_btn.text = "◀ Prev"
	prev_btn.tooltip_text = "Previous file (← / A)"
	prev_btn.pressed.connect(_go_prev)
	prev_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(prev_btn)

	# Video controls
	_vid_bar = HBoxContainer.new()
	_vid_bar.add_theme_constant_override("separation", 6)
	_vid_bar.visible = false
	_vid_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_vid_bar)

	_play_btn = Button.new()
	_play_btn.text = "▶"
	_play_btn.custom_minimum_size.x = 36
	_play_btn.tooltip_text = "Play / Pause (Space)"
	_play_btn.pressed.connect(_toggle_play)
	_play_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_vid_bar.add_child(_play_btn)

	_seek_bar = HSlider.new()
	_seek_bar.min_value = 0.0
	_seek_bar.max_value = 1.0
	_seek_bar.step      = 0.0001
	_seek_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seek_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_seek_bar.drag_ended.connect(_on_seek_drag_ended)
	_vid_bar.add_child(_seek_bar)

	_time_lbl = Label.new()
	_time_lbl.text = "0:00 / 0:00"
	_time_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_time_lbl.custom_minimum_size.x = 90
	_vid_bar.add_child(_time_lbl)

	var center_fill := Control.new()
	center_fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(center_fill)

	var next_btn := Button.new()
	next_btn.text = "Next ▶"
	next_btn.tooltip_text = "Next file (→ / D)"
	next_btn.pressed.connect(_go_next)
	next_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(next_btn)

	_pad(hbox, 6)


func _pad(parent: Control, px: int) -> void:
	var c := Control.new()
	c.custom_minimum_size.x = px
	parent.add_child(c)


# ──────────────────────────── Loading ──────────────────────────────

func open_media(path: String, files: Array) -> void:
	_files = files
	_idx   = _files.find(path)
	_load_current()


func _load_current() -> void:
	if _files.is_empty():
		return

	var path: String = _files[_idx]
	var ext := path.get_extension().to_lower()
	_is_video = ext in VIDEO_EXT

	if _vid_player.is_playing():
		_vid_player.stop()
	_vid_player.stream   = null
	_img_rect.texture    = null
	_img_size            = Vector2.ZERO
	_error_label.visible = false

	if _is_video:
		_load_video(path)
	else:
		_load_image(path)

	_file_lbl.text = path.get_file()
	_nav_lbl.text  = "%d / %d" % [_idx + 1, _files.size()]
	_vid_bar.visible = _is_video

	# Defer fit so the node has its final size.
	_reset_transform.call_deferred()


func _load_image(path: String) -> void:
	_img_rect.visible   = true
	_vid_player.visible = false

	var img := Image.load_from_file(path)
	if img:
		_img_size = Vector2(img.get_width(), img.get_height())
		_img_rect.texture = ImageTexture.create_from_image(img)
	else:
		push_warning("GalleryViewer: could not load image: " + path)


func _load_video(path: String) -> void:
	_img_rect.visible   = false
	_vid_player.visible = true

	var ext := path.get_extension().to_lower()
	var stream: VideoStream = null

	match ext:
		"ogv":
			var s := VideoStreamTheora.new()
			s.set_file(path)
			stream = s
		"webm":
			if ClassDB.class_exists("VideoStreamWebm"):
				var s: VideoStream = ClassDB.instantiate("VideoStreamWebm")
				s.call("set_file", path)
				stream = s
		_:
			# mp4, avi, mkv, mov and others are not supported by Godot natively.
			# A GDExtension (e.g. ffmpeg plugin) would be required.
			pass

	if stream:
		_vid_player.stream = stream
		_vid_player.play()
		_play_btn.text = "⏸"
	else:
		_vid_player.visible  = false
		_error_label.text    = "Cannot play  %s\n\n" % path.get_file() \
			+ "Godot supports OGV (Theora) and WebM (VP8/VP9) natively.\n" \
			+ "MP4, AVI, MKV and MOV require a video GDExtension plugin."
		_error_label.visible = true


func _on_video_finished() -> void:
	_play_btn.text = "▶"


# ──────────────────────────── Transform ────────────────────────────

func _reset_transform() -> void:
	_zoom    = 1.0
	_rot_deg = 0.0
	_pan     = Vector2.ZERO
	_apply_transform()


func _do_fit() -> void:
	_zoom    = 1.0
	_rot_deg = snappedf(_rot_deg, 90.0)
	_pan     = Vector2.ZERO
	_apply_transform()


func _do_actual_size() -> void:
	_pan = Vector2.ZERO
	if _img_size.x > 0.0 and _img_size.y > 0.0:
		# zoom level where 1 content pixel == 1 screen pixel
		var vp := size
		_zoom = max(_img_size.x / vp.x, _img_size.y / vp.y)
	else:
		_zoom = 1.0
	_apply_transform()


func _rotate_by(deg: float) -> void:
	_rot_deg = fmod(_rot_deg + deg, 360.0)
	_apply_transform()


## Zoom toward a specific screen-space point (cursor or pinch centre).
func _zoom_at(factor: float, screen_pos: Vector2) -> void:
	var old_zoom := _zoom
	_zoom = clamp(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	var zoom_ratio := _zoom / old_zoom

	# Keep the world point under screen_pos stationary.
	# Derivation: new_pan = D*(1−r) + old_pan*r  where D = screen_pos − vp_centre
	var d := screen_pos - size * 0.5
	_pan = d * (1.0 - zoom_ratio) + _pan * zoom_ratio

	_apply_transform()


func _apply_transform() -> void:
	var vp := size
	_anchor.size         = vp
	_anchor.pivot_offset = vp * 0.5
	_anchor.position     = _pan
	_anchor.scale        = Vector2(_zoom, _zoom)
	_anchor.rotation_degrees = _rot_deg

	_img_rect.size   = vp
	_vid_player.size = vp

	_zoom_lbl.text = "%d%%" % int(_zoom * 100.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_instance_valid(_anchor):
		_apply_transform()


# ──────────────────────────── Navigation ───────────────────────────

func _go_back() -> void:
	if _vid_player.is_playing():
		_vid_player.stop()
	back_pressed.emit()


func _go_prev() -> void:
	if _files.is_empty():
		return
	_idx = (_idx - 1 + _files.size()) % _files.size()
	_load_current()


func _go_next() -> void:
	if _files.is_empty():
		return
	_idx = (_idx + 1) % _files.size()
	_load_current()


# ──────────────────────────── Video controls ───────────────────────

func _toggle_play() -> void:
	if not _is_video:
		return
	if _vid_player.is_playing():
		_vid_player.paused = not _vid_player.paused
		_play_btn.text = "▶" if _vid_player.paused else "⏸"
	else:
		_vid_player.play()
		_play_btn.text = "⏸"


func _on_seek_drag_ended(changed: bool) -> void:
	if not changed or not _is_video or _vid_player.stream == null:
		return
	var len := _vid_player.get_stream_length()
	if len > 0.0:
		_vid_player.stream_position = _seek_bar.value * len


var _seek_user_dragging := false

func _process(_dt: float) -> void:
	if not visible or not _is_video or _vid_player.stream == null:
		return
	# Don't overwrite seek bar while user is dragging it.
	if _seek_bar.has_focus():
		return
	var len := _vid_player.get_stream_length()
	if len > 0.0:
		var pos := _vid_player.stream_position
		_seek_bar.set_value_no_signal(pos / len)
		_time_lbl.text = "%s / %s" % [_fmt_time(pos), _fmt_time(len)]


func _fmt_time(sec: float) -> String:
	var s := int(sec)
	return "%d:%02d" % [s / 60, s % 60]


# ──────────────────────────── Input ────────────────────────────────

func _input(event: InputEvent) -> void:
	if not visible:
		return

	# Sustain drag even when mouse travels over UI buttons.
	if _dragging:
		if event is InputEventMouseMotion:
			_pan = _drag_pan_start + (event.position - _drag_mouse_start)
			_apply_transform()
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT \
				and not event.pressed:
			_dragging = false
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventKey:
		if event.pressed:
			_handle_key(event)
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
		return

	# Touchpad pinch-to-zoom
	if event is InputEventMagnifyGesture:
		_zoom_at(event.factor, event.position)
		get_viewport().set_input_as_handled()
		return

	# Touchpad two-finger pan
	if event is InputEventPanGesture:
		# delta is in pixels; positive Y = scroll down
		_pan -= event.delta * 2.5
		_apply_transform()
		get_viewport().set_input_as_handled()
		return


func _handle_key(ev: InputEventKey) -> void:
	match ev.keycode:
		KEY_ESCAPE:
			_go_back()
		KEY_LEFT, KEY_A:
			_go_prev()
		KEY_RIGHT, KEY_D:
			_go_next()
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			_zoom_at(1.0 + ZOOM_STEP * 2, size * 0.5)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(1.0 - ZOOM_STEP * 2, size * 0.5)
		KEY_0, KEY_KP_0:
			_do_actual_size()
		KEY_F:
			_do_fit()
		KEY_Q:
			_rotate_by(-90.0)
		KEY_R, KEY_E:
			if ev.shift_pressed:
				_rotate_by(-90.0)
			else:
				_rotate_by(90.0)
		KEY_SPACE:
			_toggle_play()


func _handle_mouse_button(ev: InputEventMouseButton) -> void:
	match ev.button_index:
		MOUSE_BUTTON_LEFT:
			if ev.pressed and not ev.double_click:
				_dragging          = true
				_drag_mouse_start  = ev.position
				_drag_pan_start    = _pan
			elif ev.double_click:
				# Double-click: toggle between fit and 2× zoom
				if absf(_zoom - 1.0) < 0.05:
					_zoom_at(2.0 / _zoom, ev.position)
				else:
					_do_fit()

		MOUSE_BUTTON_WHEEL_UP:
			# Ctrl held = larger step; plain = normal step
			var factor := 1.0 + ZOOM_STEP * (2.0 if ev.ctrl_pressed else 1.0)
			_zoom_at(factor, ev.position)
			get_viewport().set_input_as_handled()

		MOUSE_BUTTON_WHEEL_DOWN:
			var factor := 1.0 - ZOOM_STEP * (2.0 if ev.ctrl_pressed else 1.0)
			_zoom_at(factor, ev.position)
			get_viewport().set_input_as_handled()

		MOUSE_BUTTON_MIDDLE:
			if ev.pressed:
				_do_fit()
