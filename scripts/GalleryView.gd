## Gallery grid – browse local media with in-app folder navigation.
extends Control

signal open_file(path: String, all_files: Array)

const IMAGE_EXT := ["png", "jpg", "jpeg", "bmp", "webp", "tga", "svg"]
const VIDEO_EXT := ["mp4", "webm", "ogv", "avi", "mkv", "mov"]
const THUMB_W   := 168
const THUMB_H   := 148
const THUMB_IMG := 128
const MAX_THUMB_TASKS := 8
const THUMB_CACHE_MAX := 1024
const ZOOM_MIN   := 0.5
const ZOOM_MAX   := 2.5
const ZOOM_STEP  := 0.25
const PREFS_PATH := "user://prefs.cfg"

var _loading_count := 0
var _nav_gen: int = 0
var _zoom: float = 1.0

var _thumb_cache: Dictionary = {}             # key: "path|mtime|w|h" → ImageTexture
var _thumb_cache_order: Array[String] = []    # LRU queue, oldest first
var _ffmpeg_path := ""                        # empty = unchecked, "NONE" = not found

var _current_folder: String = ""
var _files: Array[String] = []       # media files in current folder
var _subfolders: Array[String] = []  # subdirectory paths in current folder
var _history: Array[String] = []     # visited folder paths
var _history_pos: int = -1           # current position in _history

enum SortMode { NAME, MODIFIED, SIZE, TYPE }
var _sort_mode: SortMode = SortMode.NAME
var _sort_asc: bool = true

# Stat caches reused by sort comparator and nav-rail landmark generation.
var _mtime_cache: Dictionary = {}    # path → int (unix mtime)
var _size_cache: Dictionary = {}     # path → int (bytes)

const MONTH_NAMES := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const SIZE_BOUNDARIES := [1024, 10240, 102400, 1048576, 10485760,
		104857600, 1073741824]
const SIZE_LABELS := ["<1 KB", "1–10 KB", "10–100 KB", "100 KB–1 MB",
		"1–10 MB", "10–100 MB", "100 MB–1 GB", ">1 GB"]
const SIZE_MAJOR_BUCKET := [false, false, false, true, false, false, true, true]

@onready var _grid: VirtualGrid = %Grid
@onready var _scroll: ScrollContainer = %Scroll
@onready var _nav_rail: ScrollNavRail = %NavRail
@onready var _status_label: Label = %StatusLabel
@onready var _breadcrumb_bar: HBoxContainer = %BreadcrumbBar
@onready var _crumb_scroll: ScrollContainer = %CrumbScroll
@onready var _path_edit: LineEdit = %PathEdit
@onready var _up_btn: Button = %UpBtn
@onready var _zoom_slider: HSlider = %ZoomSlider
@onready var _zoom_pct_lbl: Label = %ZoomPctLbl
@onready var _sort_btn: OptionButton = %SortBtn
@onready var _sort_dir_btn: Button = %SortDirBtn


# ──────────────────────────── Setup ────────────────────────────────

func _ready() -> void:
	%UpBtn.pressed.connect(_go_up)
	%CrumbScroll.gui_input.connect(_on_crumb_area_input)
	%PathEdit.text_submitted.connect(_on_path_submitted)
	%PathEdit.gui_input.connect(_on_path_edit_input)
	%PathEdit.focus_exited.connect(_exit_edit_mode)
	%ZoomOutBtn.pressed.connect(_zoom_out)
	%ZoomSlider.value_changed.connect(_on_zoom_changed)
	%ZoomInBtn.pressed.connect(_zoom_in)

	for entry in [["Name", SortMode.NAME], ["Modified", SortMode.MODIFIED],
			["Size", SortMode.SIZE], ["Type", SortMode.TYPE]]:
		%SortBtn.add_item(entry[0], entry[1])
	%SortBtn.selected = 0
	%SortBtn.item_selected.connect(_on_sort_mode_changed)
	%SortDirBtn.pressed.connect(_on_sort_dir_toggled)

	var win := get_window()
	if win:
		win.files_dropped.connect(_on_files_dropped)

	# Load prefs first so _zoom reflects on-disk state before we hand the
	# resolved item dimensions to the grid.
	_load_prefs()

	_grid.item_width = _tw()
	_grid.item_height = _th()
	_grid.configure(
		func() -> int: return _subfolders.size() + _files.size(),
		func(idx: int) -> Control:
			return _make_folder_item(_subfolders[idx]) if idx < _subfolders.size() \
				else _make_file_thumb(idx - _subfolders.size())
	)

	_scroll.get_v_scroll_bar().value_changed.connect(_on_scroll_changed)
	_grid.resized.connect(_refresh_nav_rail)
	_nav_rail.seek_requested.connect(_on_nav_seek)

	# Open Downloads by default; fall back to home directory.
	var dl := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if dl != "" and DirAccess.dir_exists_absolute(dl):
		_navigate_to(dl)
	else:
		var home := OS.get_environment("HOME")
		if home != "":
			_navigate_to(home)


# Computed thumbnail dimensions at the current zoom level.
func _tw() -> int: return int(THUMB_W * _zoom)
func _th() -> int: return int(THUMB_H * _zoom)
func _ti() -> int: return int(THUMB_IMG * _zoom)


# ──────────────────────────── Navigation ───────────────────────────

func _navigate_to(folder: String, push_history: bool = true) -> void:
	if push_history:
		# Drop any forward entries when branching to a new location.
		if _history_pos < _history.size() - 1:
			_history.resize(_history_pos + 1)
		_history.append(folder)
		_history_pos = _history.size() - 1
	_current_folder = folder
	_files.clear()
	_subfolders.clear()
	_mtime_cache.clear()
	_size_cache.clear()

	var dir := DirAccess.open(folder)
	if not dir:
		_status_label.text = "Could not open:\n" + folder
		_status_label.visible = true
		_up_btn.disabled = true
		_update_breadcrumbs()
		return

	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not fname.begins_with("."):   # skip hidden entries
			if dir.current_is_dir():
				_subfolders.append(folder.path_join(fname))
			else:
				var ext := fname.get_extension().to_lower()
				if ext in IMAGE_EXT or ext in VIDEO_EXT:
					_files.append(folder.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()

	_up_btn.disabled = (folder.get_base_dir() == folder)
	_update_breadcrumbs()
	_apply_sort()


func _go_back() -> void:
	if _history_pos > 0:
		_history_pos -= 1
		_navigate_to(_history[_history_pos], false)


func _go_forward() -> void:
	if _history_pos < _history.size() - 1:
		_history_pos += 1
		_navigate_to(_history[_history_pos], false)


func _go_up() -> void:
	var parent := _current_folder.get_base_dir()
	if parent != _current_folder:
		_navigate_to(parent)


# Re-scan the current folder to pick up added/removed/renamed files, keeping the
# user where they were scrolled rather than jumping back to the top.
func _refresh_folder() -> void:
	if _current_folder == "":
		return
	var scroll := _scroll.scroll_vertical
	_navigate_to(_current_folder, false)
	# _navigate_to → _apply_sort → _refresh_grid rebuilds the grid this frame;
	# restore scroll once the new layout's size is settled.
	await get_tree().process_frame
	_scroll.scroll_vertical = scroll


func _update_breadcrumbs() -> void:
	for c in _breadcrumb_bar.get_children():
		c.queue_free()

	if _current_folder == "":
		_add_crumb_label("No folder open")
		return

	# On macOS/Linux paths begin with "/"; split and rebuild segments.
	var parts := _current_folder.split("/", false)
	var accumulated := "/"

	_add_crumb_btn("/", "/")

	for i in parts.size():
		accumulated = (accumulated + "/" + parts[i]).simplify_path()
		_add_crumb_label(" › ")
		if i == parts.size() - 1:
			_add_crumb_label(parts[i])   # current folder – not clickable
		else:
			_add_crumb_btn(parts[i], accumulated)


func _add_crumb_btn(label: String, path: String) -> void:
	var btn := Button.new()
	btn.text = label
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(func() -> void: _navigate_to(path))
	_breadcrumb_bar.add_child(btn)


func _add_crumb_label(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_breadcrumb_bar.add_child(lbl)


# ──────────────────────────── Address-bar edit mode ────────────────

func _on_crumb_area_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_enter_edit_mode()


func _enter_edit_mode() -> void:
	_path_edit.text = _current_folder
	_crumb_scroll.visible = false
	_path_edit.visible = true
	_path_edit.grab_focus()
	_path_edit.select_all()


func _exit_edit_mode() -> void:
	_path_edit.visible = false
	_crumb_scroll.visible = true


func _on_path_submitted(text: String) -> void:
	_exit_edit_mode()
	var clean := text.strip_edges()
	if clean.length() > 1 and clean.ends_with("/"):
		clean = clean.left(clean.length() - 1)
	if clean != "" and DirAccess.dir_exists_absolute(clean):
		_navigate_to(clean)


func _on_path_edit_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_ESCAPE:
		_exit_edit_mode()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_TAB:
		_do_tab_complete()
		get_viewport().set_input_as_handled()


func _do_tab_complete() -> void:
	var text := _path_edit.text
	var dir_part: String
	var partial: String

	if text.ends_with("/"):
		dir_part = text
		partial = ""
	else:
		var slash_idx := text.rfind("/")
		if slash_idx < 0:
			return
		dir_part = text.substr(0, slash_idx + 1)
		partial = text.substr(slash_idx + 1)

	var dir := DirAccess.open(dir_part)
	if not dir:
		return

	var matches: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir() and not fname.begins_with("."):
			if partial == "" or fname.to_lower().begins_with(partial.to_lower()):
				matches.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	matches.sort()
	if matches.is_empty():
		return

	if matches.size() == 1:
		_path_edit.text = dir_part.path_join(matches[0]) + "/"
	else:
		var common := matches[0]
		for m in matches.slice(1):
			var i := 0
			while i < common.length() and i < m.length() and common[i] == m[i]:
				i += 1
			common = common.substr(0, i)
		_path_edit.text = dir_part.path_join(common)

	_path_edit.caret_column = _path_edit.text.length()


# ──────────────────────────── Grid ─────────────────────────────────

# Full reset: invalidate in-flight thumbs and rebuild from scratch scrolled to
# the top. Used on navigate / sort / drag-drop.
func _refresh_grid() -> void:
	_nav_gen += 1
	if _subfolders.is_empty() and _files.is_empty():
		_status_label.text = "This folder contains no media files or subfolders."
		_status_label.visible = true
		_grid.reload()
		return
	_status_label.visible = false
	_grid.reload()


func _make_folder_item(path: String) -> Control:
	var folder_name := path.get_file()
	var tw := _tw()
	var th := _th()
	var ti := _ti()

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(tw, th)
	btn.tooltip_text = folder_name
	btn.pressed.connect(func() -> void: _navigate_to(path))

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn.add_child(vbox)

	var bg := ColorRect.new()
	bg.custom_minimum_size = Vector2(tw - 8, ti)
	bg.color = Color("#252515")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(bg)

	var icon := Label.new()
	icon.text = "📁"
	icon.add_theme_font_size_override("font_size", int(52 * _zoom))
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = folder_name
	name_lbl.clip_text = true
	name_lbl.custom_minimum_size.x = tw - 8
	name_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(name_lbl)

	return btn


func _make_file_thumb(index: int) -> Control:
	var path := _files[index]
	var is_video := path.get_extension().to_lower() in VIDEO_EXT
	var tw := _tw()
	var th := _th()
	var ti := _ti()

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(tw, th)
	btn.tooltip_text = path.get_file()
	btn.pressed.connect(func() -> void: open_file.emit(path, _files))

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn.add_child(vbox)

	if is_video:
		if _ffmpeg_available():
			var wrapper := Control.new()
			wrapper.custom_minimum_size = Vector2(tw - 8, ti)
			wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
			vbox.add_child(wrapper)

			var placeholder := ColorRect.new()
			placeholder.color = Color("#1a1a1a")
			placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
			placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			wrapper.add_child(placeholder)

			var loading_lbl := Label.new()
			loading_lbl.text = "⏳"
			loading_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			loading_lbl.add_theme_font_size_override("font_size", int(36 * _zoom))
			loading_lbl.modulate = Color(1, 1, 1, 0.5)
			loading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			loading_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
			loading_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			placeholder.add_child(loading_lbl)

			var tex_rect := TextureRect.new()
			tex_rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
			tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			wrapper.add_child(tex_rect)
			_load_video_thumb_deferred(path, tex_rect, placeholder, tw, ti)
		else:
			var placeholder := ColorRect.new()
			placeholder.custom_minimum_size = Vector2(tw - 8, ti)
			placeholder.color = Color("#1a2040")
			placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
			vbox.add_child(placeholder)

			var lbl := Label.new()
			lbl.text = "▶  VIDEO"
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
			lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			placeholder.add_child(lbl)
	else:
		var wrapper := Control.new()
		wrapper.custom_minimum_size = Vector2(tw - 8, ti)
		wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(wrapper)

		var placeholder := ColorRect.new()
		placeholder.color = Color("#1a1a1a")
		placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		wrapper.add_child(placeholder)

		var loading_lbl := Label.new()
		loading_lbl.text = "⏳"
		loading_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		loading_lbl.add_theme_font_size_override("font_size", int(36 * _zoom))
		loading_lbl.modulate = Color(1, 1, 1, 0.5)
		loading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		loading_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		loading_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		placeholder.add_child(loading_lbl)

		var tex_rect := TextureRect.new()
		tex_rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		wrapper.add_child(tex_rect)
		_load_thumb_deferred(path, tex_rect, placeholder, tw, ti)

	var name_lbl := Label.new()
	name_lbl.text = path.get_file()
	name_lbl.clip_text = true
	name_lbl.custom_minimum_size.x = tw - 8
	name_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(name_lbl)

	return btn


func _load_thumb_deferred(path: String, tex_rect: TextureRect, placeholder: ColorRect, w: int, h: int) -> void:
	if not is_instance_valid(tex_rect):
		return
	var gen := _nav_gen

	# Cache hit: paint immediately, no hourglass flash, no worker task.
	var key := "%s|%d|%d|%d" % [path, FileAccess.get_modified_time(path), w, h]
	if _thumb_cache.has(key):
		if is_instance_valid(placeholder): placeholder.hide()
		if is_instance_valid(tex_rect): tex_rect.texture = _thumb_cache[key]
		_touch_cache(key)
		return

	# Yield once so the grid + placeholders paint before any thumb work begins.
	await get_tree().process_frame
	if gen != _nav_gen or not is_instance_valid(tex_rect):
		return

	while _loading_count >= MAX_THUMB_TASKS:
		if gen != _nav_gen or not is_inside_tree():
			return
		await get_tree().process_frame

	if not is_instance_valid(tex_rect):
		return

	_loading_count += 1
	var state := {"img": null, "done": false}

	WorkerThreadPool.add_task(func() -> void:
		var loaded := Image.load_from_file(path)
		if loaded:
			var sw := loaded.get_width()
			var sh := loaded.get_height()
			if sw > 0 and sh > 0:
				var scale := minf(float(w) / sw, float(h) / sh)
				if scale < 1.0:
					loaded.resize(int(sw * scale), int(sh * scale), Image.INTERPOLATE_BILINEAR)
			state["img"] = loaded
		state["done"] = true
	)

	while not state["done"]:
		if gen != _nav_gen or not is_inside_tree():
			_loading_count -= 1
			return
		await get_tree().process_frame

	_loading_count -= 1
	if gen != _nav_gen:
		return

	var img := state["img"] as Image
	if not img:
		return
	var tex := ImageTexture.create_from_image(img)
	_thumb_cache[key] = tex
	_touch_cache(key)
	if is_instance_valid(placeholder):
		placeholder.hide()
	if is_instance_valid(tex_rect):
		tex_rect.texture = tex


func _touch_cache(key: String) -> void:
	_thumb_cache_order.erase(key)
	_thumb_cache_order.append(key)
	while _thumb_cache_order.size() > THUMB_CACHE_MAX:
		var evict: String = _thumb_cache_order.pop_front()
		_thumb_cache.erase(evict)


func _ffmpeg_available() -> bool:
	if _ffmpeg_path == "":
		for candidate in ["ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]:
			var out := []
			if OS.execute(candidate, ["-version"], out, true) == 0:
				_ffmpeg_path = candidate
				return true
		_ffmpeg_path = "NONE"
		return false
	return _ffmpeg_path != "NONE"


func _load_video_thumb_deferred(path: String, tex_rect: TextureRect, placeholder: ColorRect, w: int, h: int) -> void:
	if not is_instance_valid(tex_rect):
		return
	var gen := _nav_gen

	var mtime := FileAccess.get_modified_time(path)
	var key := "v|%s|%d|%d|%d" % [path, mtime, w, h]
	if _thumb_cache.has(key):
		if is_instance_valid(placeholder): placeholder.hide()
		if is_instance_valid(tex_rect): tex_rect.texture = _thumb_cache[key]
		_touch_cache(key)
		return

	await get_tree().process_frame
	if gen != _nav_gen or not is_instance_valid(tex_rect):
		return

	while _loading_count >= MAX_THUMB_TASKS:
		if gen != _nav_gen or not is_inside_tree():
			return
		await get_tree().process_frame

	if not is_instance_valid(tex_rect):
		return

	_loading_count += 1
	var state := {"img": null, "done": false}
	var tmp := OS.get_user_data_dir().path_join("vthumb_%s_%d_%d.png" % [path.md5_text(), w, h])

	WorkerThreadPool.add_task(func() -> void:
		var out := []
		OS.execute(_ffmpeg_path, [
			"-y",
			"-i", path,
			"-ss", "00:00:01",
			"-vframes", "1",
			"-f", "image2",
			tmp
		], out, true)
		var loaded := Image.load_from_file(tmp)
		if loaded:
			var sw := loaded.get_width()
			var sh := loaded.get_height()
			if sw > 0 and sh > 0:
				var scale := minf(float(w) / sw, float(h) / sh)
				if scale < 1.0:
					loaded.resize(int(sw * scale), int(sh * scale), Image.INTERPOLATE_BILINEAR)
			state["img"] = loaded
		DirAccess.remove_absolute(tmp)
		state["done"] = true
	)

	while not state["done"]:
		if gen != _nav_gen or not is_inside_tree():
			_loading_count -= 1
			return
		await get_tree().process_frame

	_loading_count -= 1
	if gen != _nav_gen:
		return

	var img := state["img"] as Image
	if not img:
		return
	var tex := ImageTexture.create_from_image(img)
	_thumb_cache[key] = tex
	_touch_cache(key)
	if is_instance_valid(placeholder):
		placeholder.hide()
	if is_instance_valid(tex_rect):
		tex_rect.texture = tex


# ──────────────────────────── Zoom ─────────────────────────────────

func _zoom_in() -> void:
	_on_zoom_changed(clampf(_zoom + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX))


func _zoom_out() -> void:
	_on_zoom_changed(clampf(_zoom - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX))


func _on_zoom_changed(value: float) -> void:
	_zoom = clampf(value, ZOOM_MIN, ZOOM_MAX)
	if is_instance_valid(_zoom_slider):
		_zoom_slider.set_value_no_signal(_zoom)
	if is_instance_valid(_zoom_pct_lbl):
		_zoom_pct_lbl.text = "%d%%" % int(_zoom * 100)
	# Item dimensions changed — invalidate inflight thumb tasks; the grid rebuilds
	# its existing items at the new size and preserves the user's scroll position.
	_nav_gen += 1
	_grid.set_item_size(_tw(), _th())
	_save_prefs()
	call_deferred("_refresh_nav_rail")


# ──────────────────────────── Sorting ──────────────────────────────

func _on_sort_mode_changed(index: int) -> void:
	_sort_mode = index as SortMode
	_apply_sort()
	_save_prefs()


func _on_sort_dir_toggled() -> void:
	_sort_asc = not _sort_asc
	_sort_dir_btn.text = "↑" if _sort_asc else "↓"
	_apply_sort()
	_save_prefs()


func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return
	_zoom = clampf(cfg.get_value("gallery", "zoom", _zoom), ZOOM_MIN, ZOOM_MAX)
	_zoom_slider.set_value_no_signal(_zoom)
	_zoom_pct_lbl.text = "%d%%" % int(_zoom * 100)
	_sort_mode = cfg.get_value("gallery", "sort_mode", _sort_mode) as SortMode
	_sort_btn.select(_sort_mode)
	_sort_asc = cfg.get_value("gallery", "sort_asc", _sort_asc)
	_sort_dir_btn.text = "↑" if _sort_asc else "↓"


func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("gallery", "zoom", _zoom)
	cfg.set_value("gallery", "sort_mode", int(_sort_mode))
	cfg.set_value("gallery", "sort_asc", _sort_asc)
	cfg.save(PREFS_PATH)


func _apply_sort() -> void:
	var file_cmp := _make_file_cmp()
	_files.sort_custom(file_cmp)
	_subfolders.sort_custom(func(a, b): return a.get_file().to_lower() < b.get_file().to_lower())
	if not _sort_asc:
		_files.reverse()
		_subfolders.reverse()
	_refresh_grid()
	call_deferred("_refresh_nav_rail")


func _make_file_cmp() -> Callable:
	match _sort_mode:
		SortMode.MODIFIED:
			for p in _files:
				_mtime_for(p)
			return func(a, b): return _mtime_cache[a] < _mtime_cache[b]
		SortMode.SIZE:
			for p in _files:
				_size_for(p)
			return func(a, b): return _size_cache[a] < _size_cache[b]
		SortMode.TYPE:
			return func(a, b):
				var ea: String = a.get_extension().to_lower()
				var eb: String = b.get_extension().to_lower()
				return ea < eb if ea != eb else a.get_file().to_lower() < b.get_file().to_lower()
		_:
			return func(a, b): return a.get_file().to_lower() < b.get_file().to_lower()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F6 or (event.keycode == KEY_L and event.is_command_or_control_pressed()):
			_enter_edit_mode()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F5 or (event.keycode == KEY_R and event.is_command_or_control_pressed()):
			_refresh_folder()
			get_viewport().set_input_as_handled()
			return
		if event.alt_pressed:
			if event.keycode == KEY_LEFT:
				_go_back()
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_RIGHT:
				_go_forward()
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_UP:
				_go_up()
				get_viewport().set_input_as_handled()
				return
		if not event.alt_pressed and not event.ctrl_pressed and not event.shift_pressed:
			var count := _grid.total_count()
			var cur := _grid.selected_index() if _grid.selected_index() >= 0 else 0
			var cols := _grid.column_count()
			match event.keycode:
				KEY_LEFT:
					_grid.select_index(cur - 1)
					get_viewport().set_input_as_handled()
				KEY_RIGHT:
					_grid.select_index(cur + 1)
					get_viewport().set_input_as_handled()
				KEY_UP:
					_grid.select_index(cur - cols)
					get_viewport().set_input_as_handled()
				KEY_DOWN:
					_grid.select_index(cur + cols)
					get_viewport().set_input_as_handled()
				KEY_HOME:
					_grid.select_index(0)
					get_viewport().set_input_as_handled()
				KEY_END:
					_grid.select_index(count - 1)
					get_viewport().set_input_as_handled()
				KEY_ENTER, KEY_KP_ENTER:
					var sel := _grid.selected_index()
					if sel >= 0 and count > 0:
						var btn := _grid.get_visible_item(sel) as Button
						if btn:
							btn.pressed.emit()
					get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed and event.ctrl_pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_in()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_out()
			get_viewport().set_input_as_handled()


# ──────────────────────────── Drag-and-drop ────────────────────────

func _on_files_dropped(paths: PackedStringArray) -> void:
	# Directory-wins: if any dropped path is a directory, navigate to the
	# first such directory and ignore everything else.
	for path in paths:
		if not FileAccess.file_exists(path) and DirAccess.dir_exists_absolute(path):
			_navigate_to(path)
			return

	var collected: Array[String] = []
	var first_folder := ""
	for path in paths:
		if FileAccess.file_exists(path):
			var ext := path.get_extension().to_lower()
			if ext in IMAGE_EXT or ext in VIDEO_EXT:
				collected.append(path)
				if first_folder == "":
					first_folder = path.get_base_dir()

	if collected.is_empty():
		return
	collected.sort()

	# If all files share one folder, navigate there and let the normal
	# grid show them alongside any other media in that folder.
	var all_same_dir := collected.all(func(p): return p.get_base_dir() == first_folder)
	if all_same_dir and first_folder != "":
		_navigate_to(first_folder)
	else:
		# Mixed sources – just display the dropped files directly.
		_files = collected
		_subfolders.clear()
		_mtime_cache.clear()
		_size_cache.clear()
		_refresh_grid()
		call_deferred("_refresh_nav_rail")


# ──────────────────────────── Nav rail ─────────────────────────────

func _mtime_for(p: String) -> int:
	if not _mtime_cache.has(p):
		_mtime_cache[p] = int(FileAccess.get_modified_time(p))
	return _mtime_cache[p]


func _size_for(p: String) -> int:
	if not _size_cache.has(p):
		var f := FileAccess.open(p, FileAccess.READ)
		_size_cache[p] = f.get_length() if f else 0
	return _size_cache[p]


func _size_bucket(b: int) -> int:
	for i in SIZE_BOUNDARIES.size():
		if b < SIZE_BOUNDARIES[i]:
			return i
	return SIZE_BOUNDARIES.size()


func _name_key(p: String) -> String:
	var f := p.get_file()
	if f.is_empty():
		return "#"
	var c := f.substr(0, 1).to_upper()
	return c if c >= "A" and c <= "Z" else "#"


func _format_month_year(y: int, m: int) -> String:
	return "%s %d" % [MONTH_NAMES[clampi(m - 1, 0, 11)], y]


func _max_scroll() -> float:
	return _grid.custom_minimum_size.y - _scroll.size.y


func _pos_for_index(idx: int) -> float:
	var cols := maxi(1, _grid.column_count())
	var row := idx / cols
	var row_step := _grid.item_height + _grid.spacing
	var maxs := _max_scroll()
	if maxs <= 0.0:
		return 0.0
	return clampf(float(row * row_step) / maxs, 0.0, 1.0)


func _refresh_nav_rail() -> void:
	if not is_instance_valid(_nav_rail):
		return
	_nav_rail.set_landmarks(_compute_landmarks())
	_update_rail_state()


func _on_scroll_changed(_v: float) -> void:
	_update_rail_state()


func _on_nav_seek(pos: float) -> void:
	var maxs := _max_scroll()
	if maxs <= 0.0:
		return
	_scroll.scroll_vertical = int(round(pos * maxs))


func _update_rail_state() -> void:
	var maxs := _max_scroll()
	var p := 0.0 if maxs <= 0.0 else clampf(float(_scroll.scroll_vertical) / maxs, 0.0, 1.0)
	_nav_rail.set_progress(p)
	_nav_rail.set_current_label(_label_for_idx(_grid._top_visible_index()))


func _label_for_idx(idx: int) -> String:
	var total := _subfolders.size() + _files.size()
	if idx < 0 or total == 0:
		return ""
	if idx < _subfolders.size():
		return "📁 Folders"
	var p: String = _files[idx - _subfolders.size()]
	match _sort_mode:
		SortMode.NAME:
			return _name_key(p)
		SortMode.MODIFIED:
			var d := Time.get_datetime_dict_from_unix_time(_mtime_for(p))
			return _format_month_year(d["year"], d["month"])
		SortMode.SIZE:
			return SIZE_LABELS[_size_bucket(_size_for(p))]
		SortMode.TYPE:
			return "." + p.get_extension().to_lower()
	return ""


func _compute_landmarks() -> Array:
	var total := _subfolders.size() + _files.size()
	if total == 0 or _grid.column_count() <= 0:
		return []
	var out: Array = []
	if _subfolders.size() > 0:
		out.append({"pos": _pos_for_index(0), "label": "📁 Folders", "major": true})
	if _files.is_empty():
		return out
	var base := _subfolders.size()
	var sections: Array
	match _sort_mode:
		SortMode.NAME:
			sections = _sections_name(base)
		SortMode.MODIFIED:
			sections = _sections_modified(base)
		SortMode.SIZE:
			sections = _sections_size(base)
		SortMode.TYPE:
			sections = _sections_type(base)
		_:
			sections = []
	for s in sections:
		out.append({
			"pos": _pos_for_index(s["index"]),
			"label": s["label"],
			"major": s["major"],
		})
	return out


func _sections_name(base: int) -> Array:
	var per_letter: Array = []
	var prev := ""
	for i in _files.size():
		var k := _name_key(_files[i])
		if k != prev:
			per_letter.append({"index": base + i, "label": k})
			prev = k
	var out: Array = []
	if per_letter.size() <= 13:
		for s in per_letter:
			out.append({"index": s["index"], "label": s["label"], "major": true})
		return out
	var bucket_size := int(ceil(float(per_letter.size()) / 13.0))
	var i := 0
	while i < per_letter.size():
		var j := mini(i + bucket_size - 1, per_letter.size() - 1)
		var a: String = per_letter[i]["label"]
		var b: String = per_letter[j]["label"]
		var lbl: String = a if a == b else "%s–%s" % [a, b]
		out.append({
			"index": per_letter[i]["index"],
			"label": lbl,
			"major": (i / bucket_size) % 2 == 0,
		})
		i += bucket_size
	return out


func _sections_modified(base: int) -> Array:
	var months: Array = []
	var prev_y := -1
	var prev_m := -1
	for i in _files.size():
		var d := Time.get_datetime_dict_from_unix_time(_mtime_for(_files[i]))
		var y: int = d["year"]
		var m: int = d["month"]
		if y != prev_y or m != prev_m:
			months.append({"year": y, "month": m, "index": base + i})
			prev_y = y
			prev_m = m
	if months.is_empty():
		return []
	# Span may be negative if descending; use absolute values.
	var ya: int = months[0]["year"]
	var yb: int = months[months.size() - 1]["year"]
	var ma: int = months[0]["month"]
	var mb: int = months[months.size() - 1]["month"]
	var span_months: int = absi((yb - ya) * 12 + (mb - ma))
	var span_years: int = absi(yb - ya)

	var out: Array = []
	if span_months <= 24:
		for idx in months.size():
			var s: Dictionary = months[idx]
			out.append({
				"index": s["index"],
				"label": _format_month_year(s["year"], s["month"]),
				"major": s["month"] == 1 or idx == 0,
			})
	elif span_years <= 20:
		var seen := {}
		for s in months:
			if seen.has(s["year"]):
				continue
			seen[s["year"]] = true
			out.append({
				"index": s["index"],
				"label": str(s["year"]),
				"major": s["year"] % 5 == 0,
			})
	else:
		var seen2 := {}
		for s in months:
			var bucket := int(s["year"] / 5) * 5
			if seen2.has(bucket):
				continue
			seen2[bucket] = true
			out.append({
				"index": s["index"],
				"label": "%ds" % bucket,
				"major": true,
			})
	return out


func _sections_size(base: int) -> Array:
	var out: Array = []
	var prev := -1
	for i in _files.size():
		var b := _size_bucket(_size_for(_files[i]))
		if b != prev:
			out.append({
				"index": base + i,
				"label": SIZE_LABELS[b],
				"major": SIZE_MAJOR_BUCKET[b],
			})
			prev = b
	return out


func _sections_type(base: int) -> Array:
	var per_ext: Array = []
	var counts := {}
	var prev := ""
	for i in _files.size():
		var ext: String = _files[i].get_extension().to_lower()
		counts[ext] = counts.get(ext, 0) + 1
		if ext != prev:
			per_ext.append({"ext": ext, "index": base + i})
			prev = ext
	if per_ext.size() <= 12:
		var out: Array = []
		for s in per_ext:
			out.append({"index": s["index"], "label": "." + str(s["ext"]), "major": true})
		return out
	var threshold: int = maxi(1, int(0.02 * _files.size()))
	var out2: Array = []
	var in_other := false
	for s in per_ext:
		if counts[s["ext"]] >= threshold:
			in_other = false
			out2.append({"index": s["index"], "label": "." + str(s["ext"]), "major": true})
		elif not in_other:
			in_other = true
			out2.append({"index": s["index"], "label": "other", "major": false})
	return out2
