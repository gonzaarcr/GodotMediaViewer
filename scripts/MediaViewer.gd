## Full-screen media viewer with zoom, rotation, pan, and video playback.
##
## Keyboard shortcuts
##   Esc / Backspace → back to gallery (or cancel crop/trim)
##   ← / →  or  A / D   → prev / next file
##   + / - or W / ↑  → zoom in / out  (also Ctrl+scroll)
##   S / ↓            → zoom out
##   Ctrl + ← ↑ → ↓   → pan in that direction
##   Scroll wheel → zoom
##   0            → actual size (1:1 pixels)
##   F            → fit to screen  (press again to fill / cover)
##   Q            → rotate 90° counter-clockwise
##   E  or  R     → rotate 90° clockwise
##   Space        → play / pause video
##   F11          → toggle fullscreen
##   M            → mute / unmute video
##   C            → crop image (Enter to apply, Esc to cancel)
##   T            → trim video (Enter to apply, Esc to cancel)
##
## Touchpad gestures
##   Pinch        → zoom toward fingers (macOS only — Godot does not emit
##                  pinch events on Linux/X11 or Windows)
##   Two-finger scroll → pan
##                  On macOS this comes through as InputEventPanGesture.
##                  On Linux it arrives as wheel events. Godot/X11 cannot
##                  reliably distinguish touchpad from mouse wheel, so on
##                  Linux scroll = pan and Ctrl+scroll = zoom for both.
##                  On macOS/Windows scroll = zoom (mouse wheel convention).
extends Control

signal back_pressed

const IMAGE_EXT  := ["png", "jpg", "jpeg", "bmp", "webp", "tga", "svg"]
const VIDEO_EXT  := ["mp4", "webm", "ogv", "avi", "mkv", "mov"]
const ZOOM_MIN          := 0.05
const ZOOM_MAX          := 32.0
const ZOOM_STEP         := 0.12   # fractional factor per scroll tick
const KEY_PAN_STEP      := 60.0   # pixels per Ctrl+arrow press
const OVERLAY_HIDE_DELAY := 3.0   # seconds of idle before hiding
const CROP_HANDLE_SIZE  := 16
const CROP_MIN_SIZE     := 20
const TRIM_ARROW_H      := 20.0

# Transform state
var _zoom       := 1.0
var _rot_deg    := 0.0
var _pan        := Vector2.ZERO
var _img_size   := Vector2.ZERO  # natural pixel dimensions (for 1:1 calc)

# File list
var _files   : Array[String]  = []
var _idx     : int    = 0
var _is_video: bool   = false

# Tween handles (not nodes — kept as plain vars)
var _top_fade_tween  : Tween
var _bot_fade_tween  : Tween

# Drag state
var _dragging          := false
var _drag_pan_start    := Vector2.ZERO
var _drag_mouse_start  := Vector2.ZERO
var _seeking           := false

# Crop state
var _crop_mode             := false
var _crop_rect             := Rect2()
var _crop_drag             := ""
var _crop_drag_start_rect  := Rect2()
var _crop_drag_start_mouse := Vector2.ZERO

# Image load generation — incremented on each new load to cancel stale ones
var _load_gen := 0

# Trim state
var _trim_mode  := false
var _trim_in         := 0.0
var _trim_out        := 1.0
var _trim_drag       := ""
var _vol_before_mute := 1.0

@onready var _anchor         : Control           = $Clip/Anchor
@onready var _img_rect       : TextureRect       = $Clip/Anchor/ImgRect
@onready var _vid_player     : VideoStreamPlayer = $Clip/Anchor/VidPlayer
@onready var _top_bar        : Control           = $UI/TopBar
@onready var _file_lbl       : Button            = $UI/TopBar/HBox/FileLbl
@onready var _nav_lbl        : Label             = $UI/TopBar/HBox/NavLbl
@onready var _zoom_lbl       : Label             = $UI/TopBar/HBox/ZoomLbl
@onready var _bottom_bar     : Control           = $UI/BotContainer/BottomBar
@onready var _vid_bar        : Control           = $UI/BotContainer/BottomBar/HBox/VidBar
@onready var _play_btn       : Button            = $UI/BotContainer/BottomBar/HBox/VidBar/PlayBtn
@onready var _seek_bar       : HSlider           = $UI/BotContainer/BottomBar/HBox/VidBar/SeekContainer/SeekBar
@onready var _seek_container : Control           = $UI/BotContainer/BottomBar/HBox/VidBar/SeekContainer
@onready var _time_lbl       : Label             = $UI/BotContainer/BottomBar/HBox/VidBar/TimeLbl
@onready var _error_label    : Label             = $UI/ErrorLabel
@onready var _info_panel     : PanelContainer    = $UI/InfoPanel
@onready var _info_name_lbl  : Label             = $UI/InfoPanel/Margin/VBox/NameLbl
@onready var _info_dims_lbl  : Label             = $UI/InfoPanel/Margin/VBox/DimsLbl
@onready var _info_size_lbl  : Label             = $UI/InfoPanel/Margin/VBox/SizeLbl
@onready var _info_fmt_lbl   : Label             = $UI/InfoPanel/Margin/VBox/FmtLbl
@onready var _top_hide_timer : Timer             = $TopHideTimer
@onready var _bot_hide_timer : Timer             = $BotHideTimer
@onready var _crop_overlay   : Control           = $CropOverlay
@onready var _crop_dim       : Control           = $CropOverlay/CropDim
@onready var _crop_handles   : Control           = $CropOverlay/CropHandleLayer
@onready var _crop_bar       : Control           = $UI/CropBar
@onready var _crop_btn       : Button            = $UI/TopBar/HBox/CropBtn
@onready var _trim_bar       : Control           = $UI/BotContainer/TrimBar
@onready var _trim_range_lbl : Label             = $UI/BotContainer/TrimBar/HBox/TrimRangeLbl
@onready var _trim_btn        : Button  = $UI/TopBar/HBox/TrimBtn
@onready var _trim_in_handle  : Control = $UI/BotContainer/BottomBar/HBox/VidBar/SeekContainer/TrimInHandle
@onready var _trim_out_handle : Control = $UI/BotContainer/BottomBar/HBox/VidBar/SeekContainer/TrimOutHandle
@onready var _fullscreen_btn  : Button  = $UI/TopBar/HBox/FullscreenBtn
@onready var _mute_btn        : Button  = $UI/BotContainer/BottomBar/HBox/VidBar/MuteBtn
@onready var _vol_slider      : HSlider = $UI/BotContainer/BottomBar/HBox/VidBar/VolumeSlider


# ──────────────────────────── Setup ────────────────────────────────

func _ready() -> void:
	_top_hide_timer.wait_time = OVERLAY_HIDE_DELAY
	_bot_hide_timer.wait_time = OVERLAY_HIDE_DELAY
	var init_mode := DisplayServer.window_get_mode()
	_fullscreen_btn.text = "⊡" if (init_mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or init_mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN) else "⛶"

	# Lambda connections that can't be wired in the scene file
	_file_lbl.pressed.connect(_toggle_info_panel)
	$UI/TopBar/HBox/PrevBtn.pressed.connect(func() -> void: _go_prev(); _show_top(); _show_bot())
	$UI/TopBar/HBox/NextBtn.pressed.connect(func() -> void: _go_next(); _show_top(); _show_bot())
	$UI/TopBar/HBox/ZoomOutBtn.pressed.connect(func() -> void: _zoom_at(1.0 - ZOOM_STEP * 2, size * 0.5))
	$UI/TopBar/HBox/ZoomInBtn.pressed.connect(func() -> void: _zoom_at(1.0 + ZOOM_STEP * 2, size * 0.5))
	$UI/TopBar/HBox/RotLBtn.pressed.connect(func() -> void: _rotate_by(-90.0))
	$UI/TopBar/HBox/RotRBtn.pressed.connect(func() -> void: _rotate_by(90.0))
	_seek_bar.drag_started.connect(func() -> void: _seeking = true)

	_crop_dim.draw.connect(_draw_crop_dim)
	_trim_in_handle.draw.connect(func() -> void: _draw_trim_handle(_trim_in_handle, false))
	_trim_out_handle.draw.connect(func() -> void: _draw_trim_handle(_trim_out_handle, true))
	_trim_in_handle.gui_input.connect(func(e: InputEvent) -> void: _on_trim_handle_input(e, "IN"))
	_trim_out_handle.gui_input.connect(func(e: InputEvent) -> void: _on_trim_handle_input(e, "OUT"))


# ──────────────────────────── Loading ──────────────────────────────

func open_media(path: String, files: Array) -> void:
	_files = files
	_idx   = _files.find(path)
	_info_panel.visible = false
	_load_current()
	_show_top()
	_show_bot()


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

	if _crop_mode:
		_on_crop_cancel()
	if _trim_mode:
		_on_trim_cancel()

	if _is_video:
		_load_video(path)
	else:
		_load_image(path)

	_crop_btn.visible = not _is_video
	_trim_btn.visible = _is_video

	_update_info_panel(path)
	_file_lbl.text = path.get_file()
	_nav_lbl.text  = "%d / %d" % [_idx + 1, _files.size()]
	_vid_bar.visible = _is_video
	if not _is_video:
		_bottom_bar.visible = false

	# Defer fit so the node has its final size.
	_reset_transform.call_deferred()


func _load_image(path: String) -> void:
	_img_rect.visible   = true
	_img_rect.texture   = null
	_vid_player.visible = false

	_load_gen += 1
	var gen := _load_gen
	var state := {"img": null, "done": false}

	WorkerThreadPool.add_task(func() -> void:
		state["img"] = Image.load_from_file(path)
		state["done"] = true
	)

	while not state["done"]:
		if not is_inside_tree():
			return
		await get_tree().process_frame

	if gen != _load_gen:
		return

	var img := state["img"] as Image
	if img:
		_img_size = Vector2(img.get_width(), img.get_height())
		_img_rect.texture = ImageTexture.create_from_image(img)
		_reset_transform.call_deferred()
	else:
		_error_label.text = "Could not load: " + path.get_file()
		_error_label.visible = true
		_img_rect.visible = false


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
	_zoom    = _fit_zoom()
	_rot_deg = 0.0
	_pan     = Vector2.ZERO
	_apply_transform()


func _do_fit() -> void:
	_zoom    = _fit_zoom()
	_rot_deg = snappedf(_rot_deg, 90.0)
	_pan     = Vector2.ZERO
	_apply_transform()


func _do_fill() -> void:
	_zoom    = _fill_zoom()
	_rot_deg = snappedf(_rot_deg, 90.0)
	_pan     = Vector2.ZERO
	_apply_transform()


func _do_actual_size() -> void:
	_pan  = Vector2.ZERO
	_zoom = 1.0
	_apply_transform()


func _actual_scale() -> float:
	if _img_size.x > 0.0 and _img_size.y > 0.0:
		return max(_img_size.x / size.x, _img_size.y / size.y)
	return 1.0


func _fit_zoom() -> float:
	return 1.0 / _actual_scale()


func _fill_zoom() -> float:
	if _img_size.x > 0.0 and _img_size.y > 0.0:
		return max(size.x / _img_size.x, size.y / _img_size.y)
	return 1.0


func _rotate_by(deg: float) -> void:
	_rot_deg = snappedf(_rot_deg + deg, 90.0)
	_apply_transform()


func _pan_by(delta: Vector2) -> void:
	_pan += delta
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
	var s := _zoom * _actual_scale()
	_anchor.scale        = Vector2(s, s)
	_anchor.rotation_degrees = _rot_deg

	_img_rect.size   = vp
	_vid_player.size = vp

	_zoom_lbl.text = "%d%%" % int(_zoom * 100.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_instance_valid(_anchor):
		_apply_transform()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_top_hide_timer.stop()
		_bot_hide_timer.stop()


# ──────────────────────────── Navigation ───────────────────────────

func _go_back() -> void:
	if _vid_player.is_playing():
		_vid_player.stop()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_top_hide_timer.stop()
	_bot_hide_timer.stop()
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
	_seeking = false
	if not changed or not _is_video or _vid_player.stream == null:
		return
	var len_ := _vid_player.get_stream_length()
	if len_ > 0.0:
		_vid_player.stream_position = _seek_bar.value * len_


func _on_seek_bar_value_changed(value: float) -> void:
	if _vid_player.stream == null:
		return
	var len_ := _vid_player.get_stream_length()
	if len_ <= 0.0:
		return
	if _trim_mode:
		_vid_player.stream_position = value * len_
		_time_lbl.text = "%s / %s" % [_fmt_time(value * len_), _fmt_time(len_)]
	elif _seeking:
		_time_lbl.text = "%s / %s" % [_fmt_time(value * len_), _fmt_time(len_)]


func _process(_dt: float) -> void:
	if not visible or not _is_video or _vid_player.stream == null:
		return
	if _seeking:
		return
	var len_ := _vid_player.get_stream_length()
	if len_ > 0.0:
		var pos := _vid_player.stream_position
		_seek_bar.set_value_no_signal(pos / len_)
		_time_lbl.text = "%s / %s" % [_fmt_time(pos), _fmt_time(len_)]

	if _trim_mode and _seek_container.size.x > 0.0:
		_update_trim_handles()
		_update_trim_label()


func _fmt_time(sec: float) -> String:
	var s := int(sec)
	var h := s / 3600
	var m := (s % 3600) / 60
	var r := s % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, r]
	return "%d:%02d" % [m, r]


# ──────────────────────────── Overlay visibility ───────────────────

func _show_top() -> void:
	if _top_fade_tween:
		_top_fade_tween.kill()
	_top_bar.modulate.a = 1.0
	_top_bar.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_top_hide_timer.start()


func _show_bot() -> void:
	if not _is_video:
		return
	if _bot_fade_tween:
		_bot_fade_tween.kill()
	_bottom_bar.modulate.a = 1.0
	_bottom_bar.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_bot_hide_timer.start()


func _hide_top_bar() -> void:
	if _crop_mode:
		return
	_top_fade_tween = create_tween()
	_top_fade_tween.tween_property(_top_bar, "modulate:a", 0.0, 0.4)
	_top_fade_tween.tween_callback(func() -> void:
		_top_bar.visible = false
		_top_bar.modulate.a = 1.0
		if not _bottom_bar.visible and DisplayServer.window_is_focused():
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	)


func _hide_bot_bar() -> void:
	if _trim_mode:
		return
	_bot_fade_tween = create_tween()
	_bot_fade_tween.tween_property(_bottom_bar, "modulate:a", 0.0, 0.4)
	_bot_fade_tween.tween_callback(func() -> void:
		_bottom_bar.visible = false
		_bottom_bar.modulate.a = 1.0
		if not _top_bar.visible and DisplayServer.window_is_focused():
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	)


# ──────────────────────────── Input ────────────────────────────────

func _input(event: InputEvent) -> void:
	if not visible:
		return

	if _crop_mode:
		_handle_crop_input(event)
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

	# Sustain trim-handle drag; the handles are only 12 px wide so the mouse
	# leaves their bounds immediately and gui_input stops firing.
	if _trim_drag != "":
		if event is InputEventMouseMotion:
			var w := _seek_container.size.x
			if w > 0.0:
				var local_x := _seek_container.get_local_mouse_position().x
				var t := clampf(local_x / w, 0.0, 1.0)
				const MIN_GAP := 0.01
				if _trim_drag == "IN":
					_trim_in = minf(t, _trim_out - MIN_GAP)
				else:
					_trim_out = maxf(t, _trim_in + MIN_GAP)
				_update_trim_handles()
				_update_trim_label()
				_vid_player.stream_position = t * _vid_player.get_stream_length()
				_seek_bar.set_value_no_signal(t)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT \
				and not event.pressed:
			_trim_drag = ""
			get_viewport().set_input_as_handled()

	if event is InputEventMouseMotion:
		_show_top()
		_show_bot()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventKey:
		if event.pressed:
			_handle_key(event)
		return

	if _crop_mode:
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
		KEY_ESCAPE, KEY_BACKSPACE:
			if _crop_mode:
				_on_crop_cancel()
			elif _trim_mode:
				_on_trim_cancel()
			else:
				_go_back()
		KEY_C:
			if not _is_video and not _trim_mode:
				if _crop_mode:
					_on_crop_apply()
				else:
					_enter_crop_mode()
		KEY_T:
			if _is_video and not _crop_mode:
				if _trim_mode:
					_on_trim_apply()
				else:
					_enter_trim_mode()
		KEY_LEFT:
			if ev.ctrl_pressed:
				_pan_by(Vector2(KEY_PAN_STEP, 0.0))
			elif not _crop_mode and not _trim_mode:
				_go_prev()
		KEY_RIGHT:
			if ev.ctrl_pressed:
				_pan_by(Vector2(-KEY_PAN_STEP, 0.0))
			elif not _crop_mode and not _trim_mode:
				_go_next()
		KEY_UP:
			if ev.ctrl_pressed:
				_pan_by(Vector2(0.0, KEY_PAN_STEP))
			elif not _crop_mode:
				_zoom_at(1.0 + ZOOM_STEP * 2, size * 0.5)
		KEY_DOWN:
			if ev.ctrl_pressed:
				_pan_by(Vector2(0.0, -KEY_PAN_STEP))
			elif not _crop_mode:
				_zoom_at(1.0 - ZOOM_STEP * 2, size * 0.5)
		KEY_A:
			if not _crop_mode and not _trim_mode:
				_go_prev()
		KEY_D:
			if not _crop_mode and not _trim_mode:
				_go_next()
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD, KEY_W:
			if not _crop_mode:
				_zoom_at(1.0 + ZOOM_STEP * 2, size * 0.5)
		KEY_MINUS, KEY_KP_SUBTRACT, KEY_S:
			if not _crop_mode:
				_zoom_at(1.0 - ZOOM_STEP * 2, size * 0.5)
		KEY_0, KEY_KP_0:
			if not _crop_mode:
				_do_actual_size()
		KEY_F:
			if not _crop_mode:
				if absf(_zoom - _fit_zoom()) < 0.01:
					_do_fill()
				else:
					_do_fit()
		KEY_Q:
			if not _crop_mode:
				_rotate_by(-90.0)
		KEY_R, KEY_E:
			if not _crop_mode:
				if ev.shift_pressed:
					_rotate_by(-90.0)
				else:
					_rotate_by(90.0)
		KEY_SPACE:
			_toggle_play()
		KEY_F11:
			_toggle_fullscreen()
		KEY_M:
			if _is_video:
				_on_mute_pressed()


func _handle_mouse_button(ev: InputEventMouseButton) -> void:
	match ev.button_index:
		MOUSE_BUTTON_LEFT:
			if ev.pressed and not ev.double_click:
				_dragging          = true
				_drag_mouse_start  = ev.position
				_drag_pan_start    = _pan
			elif ev.double_click:
				# Double-click: toggle between fit and 2× zoom
				if absf(_zoom - _fit_zoom()) < 0.05 * _fit_zoom():
					_zoom_at(2.0 / _zoom, ev.position)
				else:
					_do_fit()

		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			var dir := 1.0 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			# Touchpad detection via fractional factor (works on Wayland/macOS
			# but not reliably on X11). Linux-side fallback: default to pan,
			# require Ctrl for zoom — matching GIMP/Inkscape/Krita.
			var is_touchpad := ev.factor > 0.0 and not is_equal_approx(ev.factor, 1.0)
			var is_linux := OS.get_name() == "Linux"
			var should_pan := (is_touchpad or is_linux) and not ev.ctrl_pressed
			print("[wheel] os=%s factor=%.3f is_touchpad=%s ctrl=%s pressed=%s should_pan=%s" \
				% [OS.get_name(), ev.factor, is_touchpad, ev.ctrl_pressed, ev.pressed, should_pan])
			if should_pan:
				var f := ev.factor if is_touchpad else 1.0
				_pan.y += 60.0 * dir * f
				_apply_transform()
			else:
				var step := ev.factor if is_touchpad else (2.0 if ev.ctrl_pressed else 1.0)
				_zoom_at(1.0 + ZOOM_STEP * dir * step, ev.position)
			get_viewport().set_input_as_handled()

		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			var dir := 1.0 if ev.button_index == MOUSE_BUTTON_WHEEL_RIGHT else -1.0
			var f := ev.factor if ev.factor > 0.0 else 1.0
			_pan.x -= 60.0 * dir * f
			_apply_transform()
			get_viewport().set_input_as_handled()

		MOUSE_BUTTON_MIDDLE:
			if ev.pressed:
				_do_fit()


# ──────────────────────────── Crop ─────────────────────────────────

func _enter_crop_mode() -> void:
	if _is_video or _img_size == Vector2.ZERO:
		return
	_crop_mode = true
	_top_hide_timer.stop()
	_bot_hide_timer.stop()
	_show_top()
	_crop_rect = _image_rect_in_screen_space()
	_crop_overlay.visible = true
	_crop_bar.visible = true
	_update_crop_handles()
	_crop_dim.queue_redraw()


func _on_crop_cancel() -> void:
	_crop_mode = false
	_crop_drag = ""
	_crop_overlay.visible = false
	_crop_bar.visible = false
	_top_hide_timer.start()


func _on_crop_apply() -> void:
	var tl_px := _screen_to_image_pixel(_crop_rect.position)
	var br_px := _screen_to_image_pixel(_crop_rect.end)

	var px_rect := Rect2i(Vector2i(tl_px), Vector2i(br_px - tl_px))
	px_rect = px_rect.intersection(Rect2i(Vector2i.ZERO, Vector2i(_img_size)))

	if px_rect.size.x <= 0 or px_rect.size.y <= 0:
		_on_crop_cancel()
		return

	var path := _files[_idx]
	var img  := Image.load_from_file(path)
	if not img:
		_on_crop_cancel()
		return

	var cropped := img.get_region(px_rect)

	# Rotate the cropped result to match what the user saw on screen.
	var rot_steps := int(snappedf(_rot_deg, 90.0) / 90.0) % 4
	if rot_steps < 0:
		rot_steps += 4
	for _i in rot_steps:
		cropped.rotate_90(CLOCKWISE)

	var out_path := _make_crop_save_path(path)
	var err: Error
	match path.get_extension().to_lower():
		"jpg", "jpeg":
			err = cropped.save_jpg(out_path)
		_:
			err = cropped.save_png(out_path)

	if err != OK:
		_error_label.text = "Could not save crop to:\n" + out_path
		_error_label.visible = true
		_on_crop_cancel()
		return

	_on_crop_cancel()
	_files[_idx] = out_path
	_load_current()


func _image_rect_in_screen_space() -> Rect2:
	var vp  := size
	var img := _img_size
	var scale_to_fit := minf(vp.x / img.x, vp.y / img.y)
	var disp    := img * scale_to_fit
	var img_tl  := (vp - disp) * 0.5

	var xf := _anchor.get_global_transform()
	var corners := [
		img_tl,
		img_tl + Vector2(disp.x, 0.0),
		img_tl + disp,
		img_tl + Vector2(0.0, disp.y),
	]
	var sc := corners.map(func(c: Vector2) -> Vector2: return xf * c)
	var mn: Vector2 = sc[0]
	var mx: Vector2 = sc[0]
	for c: Vector2 in sc.slice(1):
		mn = mn.min(c)
		mx = mx.max(c)
	return Rect2(mn, mx - mn)


func _screen_to_image_pixel(screen_pos: Vector2) -> Vector2:
	var vp  := size
	var img := _img_size
	var scale_to_fit := minf(vp.x / img.x, vp.y / img.y)
	var disp   := img * scale_to_fit
	var img_tl := (vp - disp) * 0.5

	var xf_inv  := _anchor.get_global_transform().affine_inverse()
	var content := xf_inv * screen_pos
	var rel     := content - img_tl
	var px      := rel / scale_to_fit
	return px.clamp(Vector2.ZERO, img - Vector2.ONE)


func _update_crop_handles() -> void:
	var r  := _crop_rect
	var cx := r.position.x + r.size.x * 0.5
	var cy := r.position.y + r.size.y * 0.5
	var hs := float(CROP_HANDLE_SIZE)

	var positions := {
		"TL": Vector2(r.position.x, r.position.y),
		"TM": Vector2(cx,           r.position.y),
		"TR": Vector2(r.end.x,      r.position.y),
		"ML": Vector2(r.position.x, cy),
		"MR": Vector2(r.end.x,      cy),
		"BL": Vector2(r.position.x, r.end.y),
		"BM": Vector2(cx,           r.end.y),
		"BR": Vector2(r.end.x,      r.end.y),
	}
	for child in _crop_handles.get_children():
		var key := child.name.trim_prefix("CropHandle_")
		if key in positions:
			child.size = Vector2(hs, hs)
			child.position = positions[key] - Vector2(hs * 0.5, hs * 0.5)
	_crop_dim.queue_redraw()


func _draw_crop_dim() -> void:
	var full := _crop_dim.size
	var dim  := Color(0.0, 0.0, 0.0, 0.55)
	var r    := _crop_rect

	_crop_dim.draw_rect(Rect2(0.0, 0.0, full.x, r.position.y), dim)
	_crop_dim.draw_rect(Rect2(0.0, r.end.y, full.x, full.y - r.end.y), dim)
	_crop_dim.draw_rect(Rect2(0.0, r.position.y, r.position.x, r.size.y), dim)
	_crop_dim.draw_rect(Rect2(r.end.x, r.position.y, full.x - r.end.x, r.size.y), dim)

	_crop_dim.draw_rect(r, Color(1.0, 1.0, 1.0, 0.9), false, 1.5)

	var third_x := r.size.x / 3.0
	var third_y := r.size.y / 3.0
	var gc      := Color(1.0, 1.0, 1.0, 0.25)
	_crop_dim.draw_line(Vector2(r.position.x + third_x,       r.position.y), Vector2(r.position.x + third_x,       r.end.y),      gc)
	_crop_dim.draw_line(Vector2(r.position.x + third_x * 2.0, r.position.y), Vector2(r.position.x + third_x * 2.0, r.end.y),      gc)
	_crop_dim.draw_line(Vector2(r.position.x, r.position.y + third_y),       Vector2(r.end.x, r.position.y + third_y),             gc)
	_crop_dim.draw_line(Vector2(r.position.x, r.position.y + third_y * 2.0), Vector2(r.end.x, r.position.y + third_y * 2.0),      gc)

	# Draw white squares on handles
	var hs := float(CROP_HANDLE_SIZE)
	for child in _crop_handles.get_children():
		var hp := (child as Control).position + Vector2(hs * 0.5, hs * 0.5)
		_crop_dim.draw_rect(Rect2(hp - Vector2(hs * 0.5, hs * 0.5), Vector2(hs, hs)), Color(1, 1, 1, 0.9))
		_crop_dim.draw_rect(Rect2(hp - Vector2(hs * 0.5, hs * 0.5), Vector2(hs, hs)), Color(0, 0, 0, 0.5), false, 1.0)


func _handle_crop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_crop_drag = _hit_test_crop(event.position)
			if _crop_drag != "":
				_crop_drag_start_rect  = _crop_rect
				_crop_drag_start_mouse = event.position
				get_viewport().set_input_as_handled()
		else:
			if _crop_drag != "":
				_crop_drag = ""
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if _crop_drag != "":
			_apply_crop_drag(event.position - _crop_drag_start_mouse)
			_update_crop_handles()
			get_viewport().set_input_as_handled()
		_show_top()


func _hit_test_crop(pos: Vector2) -> String:
	var hs := float(CROP_HANDLE_SIZE) * 1.5
	var r  := _crop_rect
	var cx := r.position.x + r.size.x * 0.5
	var cy := r.position.y + r.size.y * 0.5

	var handle_positions := {
		"TL": Vector2(r.position.x, r.position.y),
		"TM": Vector2(cx,           r.position.y),
		"TR": Vector2(r.end.x,      r.position.y),
		"ML": Vector2(r.position.x, cy),
		"MR": Vector2(r.end.x,      cy),
		"BL": Vector2(r.position.x, r.end.y),
		"BM": Vector2(cx,           r.end.y),
		"BR": Vector2(r.end.x,      r.end.y),
	}
	for key in handle_positions:
		if pos.distance_to(handle_positions[key]) <= hs:
			return key
	if r.has_point(pos):
		return "BODY"
	return ""


func _apply_crop_drag(delta: Vector2) -> void:
	var r      := _crop_drag_start_rect
	var min_s  := float(CROP_MIN_SIZE)
	var bounds := _image_rect_in_screen_space()

	match _crop_drag:
		"BODY":
			_crop_rect.position = (r.position + delta).clamp(
				bounds.position,
				bounds.end - _crop_rect.size
			)
		"TL":
			var new_tl := r.position + delta
			_crop_rect = Rect2(new_tl, r.end - new_tl).abs()
			if _crop_rect.size.x < min_s: _crop_rect.size.x = min_s
			if _crop_rect.size.y < min_s: _crop_rect.size.y = min_s
		"TR":
			var new_tl := Vector2(r.position.x, r.position.y + delta.y)
			var new_sz := Vector2(r.size.x + delta.x, r.size.y - delta.y)
			_crop_rect = Rect2(new_tl, new_sz).abs()
			if _crop_rect.size.x < min_s: _crop_rect.size.x = min_s
			if _crop_rect.size.y < min_s: _crop_rect.size.y = min_s
		"BL":
			var new_tl := Vector2(r.position.x + delta.x, r.position.y)
			var new_sz := Vector2(r.size.x - delta.x, r.size.y + delta.y)
			_crop_rect = Rect2(new_tl, new_sz).abs()
			if _crop_rect.size.x < min_s: _crop_rect.size.x = min_s
			if _crop_rect.size.y < min_s: _crop_rect.size.y = min_s
		"BR":
			_crop_rect = Rect2(r.position, r.size + delta).abs()
			if _crop_rect.size.x < min_s: _crop_rect.size.x = min_s
			if _crop_rect.size.y < min_s: _crop_rect.size.y = min_s
		"TM":
			var new_tl := Vector2(r.position.x, r.position.y + delta.y)
			var new_sz := Vector2(r.size.x, r.size.y - delta.y)
			_crop_rect = Rect2(new_tl, new_sz).abs()
			if _crop_rect.size.y < min_s: _crop_rect.size.y = min_s
		"BM":
			_crop_rect = Rect2(r.position, Vector2(r.size.x, r.size.y + delta.y)).abs()
			if _crop_rect.size.y < min_s: _crop_rect.size.y = min_s
		"ML":
			var new_tl := Vector2(r.position.x + delta.x, r.position.y)
			var new_sz := Vector2(r.size.x - delta.x, r.size.y)
			_crop_rect = Rect2(new_tl, new_sz).abs()
			if _crop_rect.size.x < min_s: _crop_rect.size.x = min_s
		"MR":
			_crop_rect = Rect2(r.position, Vector2(r.size.x + delta.x, r.size.y)).abs()
			if _crop_rect.size.x < min_s: _crop_rect.size.x = min_s

	_crop_rect = _crop_rect.intersection(bounds)


func _make_crop_save_path(path: String) -> String:
	var dir     := path.get_base_dir()
	var stem    := path.get_basename().get_file()
	var ext_raw := path.get_extension().to_lower()
	var ext     := "jpg" if ext_raw in ["jpg", "jpeg"] else "png"
	var candidate := dir.path_join(stem + "_crop." + ext)
	var n := 2
	while FileAccess.file_exists(candidate):
		candidate = dir.path_join("%s_crop%d.%s" % [stem, n, ext])
		n += 1
	return candidate


# ──────────────────────────── Trim ─────────────────────────────────

func _enter_trim_mode() -> void:
	if not _is_video:
		return
	_trim_mode = true
	_trim_in   = 0.0
	_trim_out  = 1.0
	_top_hide_timer.stop()
	_bot_hide_timer.stop()
	_show_top()
	_show_bot()
	if _vid_player.is_playing():
		_vid_player.paused = true
		_play_btn.text = "▶"
	_trim_bar.visible = true
	_trim_in_handle.visible  = true
	_trim_out_handle.visible = true
	_update_trim_handles()
	_update_trim_label()


func _on_trim_cancel() -> void:
	_trim_mode = false
	_trim_drag = ""
	_trim_bar.visible = false
	_trim_in_handle.visible  = false
	_trim_out_handle.visible = false
	_seek_bar.queue_redraw()
	_bot_hide_timer.start()
	_top_hide_timer.start()


func _on_trim_apply() -> void:
	var path := _files[_idx]
	var len_ := _vid_player.get_stream_length()
	if len_ <= 0.0:
		_on_trim_cancel()
		return

	var t_in  := _trim_in  * len_
	var t_out := _trim_out * len_
	var out_path := _make_trim_save_path(path)

	var ffmpeg_bin := _find_ffmpeg()
	if ffmpeg_bin.is_empty():
		_error_label.text = (
			"FFmpeg not found.\n" +
			"Install ffmpeg and make sure it is in your PATH\n" +
			"(or at /usr/local/bin/ffmpeg or /opt/homebrew/bin/ffmpeg)."
		)
		_error_label.visible = true
		return

	if _vid_player.is_playing():
		_vid_player.paused = true

	var args := [
		"-y",
		"-i",   path,
		"-ss",  "%.3f" % t_in,
		"-to",  "%.3f" % t_out,
		"-c",   "copy",
		out_path
	]

	var output := []
	var exit   := OS.execute(ffmpeg_bin, args, output, true)

	if exit != 0:
		var stderr := "\n".join(output)
		_error_label.text = (
			"FFmpeg failed (exit %d).\n%s" % [exit, stderr.substr(0, 400)]
		)
		_error_label.visible = true
		return

	_on_trim_cancel()
	_files[_idx] = out_path
	_load_current()


func _update_trim_handles() -> void:
	var w  := _seek_container.size.x
	var h  := _seek_container.size.y
	var hw := 18.0

	_trim_in_handle.size      = Vector2(hw, TRIM_ARROW_H + h)
	_trim_out_handle.size     = Vector2(hw, TRIM_ARROW_H + h)
	_trim_in_handle.position  = Vector2(_trim_in  * w - hw * 0.5, -TRIM_ARROW_H)
	_trim_out_handle.position = Vector2(_trim_out * w - hw * 0.5, -TRIM_ARROW_H)
	_trim_in_handle.queue_redraw()
	_trim_out_handle.queue_redraw()


func _draw_trim_handle(node: Control, _is_out: bool) -> void:
	var font      := ThemeDB.fallback_font
	var font_size := ThemeDB.fallback_font_size
	var c         := Color(1.0, 0.7, 0.1, 0.9)

	# ▼ rendered in the same font as the ◀ / ▶ nav buttons
	node.draw_string(
		font,
		Vector2(0.0, TRIM_ARROW_H),
		"▼",
		HORIZONTAL_ALIGNMENT_CENTER,
		node.size.x,
		font_size,
		c
	)

	# Thin marker line from arrow tip down through the seek bar
	node.draw_line(
		Vector2(node.size.x * 0.5, TRIM_ARROW_H),
		Vector2(node.size.x * 0.5, node.size.y),
		Color(1.0, 0.7, 0.1, 0.6),
		1.5
	)


func _on_trim_handle_input(event: InputEvent, which: String) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed:
		_trim_drag = which
		get_viewport().set_input_as_handled()


func _update_trim_label() -> void:
	var len_ := _vid_player.get_stream_length()
	if len_ <= 0.0:
		_trim_range_lbl.text = "Set in/out points"
		return
	var t_in  := _trim_in  * len_
	var t_out := _trim_out * len_
	var dur   := t_out - t_in
	_trim_range_lbl.text = "%s → %s  (%s)" % [_fmt_time(t_in), _fmt_time(t_out), _fmt_time(dur)]


func _find_ffmpeg() -> String:
	for candidate in ["ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]:
		var out := []
		if OS.execute(candidate, ["-version"], out, true) == 0:
			return candidate
	return ""


func _make_trim_save_path(path: String) -> String:
	var dir  := path.get_base_dir()
	var stem := path.get_basename().get_file()
	var ext  := path.get_extension().to_lower()
	var candidate := dir.path_join(stem + "_trim." + ext)
	var n := 2
	while FileAccess.file_exists(candidate):
		candidate = dir.path_join("%s_trim%d.%s" % [stem, n, ext])
		n += 1
	return candidate


# ──────────────────────────── Fullscreen & Volume ──────────────────

func _toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	var is_fs := mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
			  or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if is_fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_fullscreen_btn.text = "⛶"
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_fullscreen_btn.text = "⊡"


func _on_mute_pressed() -> void:
	if _vid_player.volume_db > -60.0:
		_vol_before_mute = db_to_linear(_vid_player.volume_db)
		_vid_player.volume_db = -80.0
		_vol_slider.set_value_no_signal(0.0)
		_mute_btn.text = "🔇"
	else:
		_vid_player.volume_db = linear_to_db(_vol_before_mute)
		_vol_slider.set_value_no_signal(_vol_before_mute)
		_mute_btn.text = "🔊"


func _on_volume_changed(value: float) -> void:
	_vid_player.volume_db = linear_to_db(value) if value > 0.0 else -80.0
	_mute_btn.text = "🔇" if value <= 0.0 else "🔊"


# ──────────────────────────── Info panel ───────────────────────────

func _toggle_info_panel() -> void:
	_info_panel.visible = not _info_panel.visible


func _update_info_panel(path: String) -> void:
	_info_name_lbl.text = path.get_file()
	_info_fmt_lbl.text  = "Format: " + path.get_extension().to_upper()

	var fa := FileAccess.open(path, FileAccess.READ)
	if fa:
		_info_size_lbl.text = "Size: " + _fmt_bytes(fa.get_length())
		fa.close()
	else:
		_info_size_lbl.text = "Size: —"

	if _is_video:
		_info_dims_lbl.text = "Dimensions: —"
	elif _img_size.x > 0.0:
		_info_dims_lbl.text = "Dimensions: %d × %d" % [int(_img_size.x), int(_img_size.y)]
	else:
		_info_dims_lbl.text = "Dimensions: —"


func _fmt_bytes(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	elif bytes < 1048576:
		return "%.1f KB" % (bytes / 1024.0)
	elif bytes < 1073741824:
		return "%.1f MB" % (bytes / 1048576.0)
	return "%.1f GB" % (bytes / 1073741824.0)
