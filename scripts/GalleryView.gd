## Gallery grid – browse local media with in-app folder navigation.
extends Control

signal open_file(path: String, all_files: Array)

const IMAGE_EXT := ["png", "jpg", "jpeg", "bmp", "webp", "tga", "svg"]
const VIDEO_EXT := ["mp4", "webm", "ogv", "avi", "mkv", "mov"]
const THUMB_W   := 168
const THUMB_H   := 148
const THUMB_IMG := 128
const ZOOM_MIN   := 0.5
const ZOOM_MAX   := 2.5
const ZOOM_STEP  := 0.25
const PREFS_PATH := "user://prefs.cfg"

var _zoom: float = 1.0
var _selected_index: int = -1

var _current_folder: String = ""
var _files: Array[String] = []       # media files in current folder
var _subfolders: Array[String] = []  # subdirectory paths in current folder
var _history: Array[String] = []     # visited folder paths
var _history_pos: int = -1           # current position in _history

enum SortMode { NAME, MODIFIED, SIZE, TYPE }
var _sort_mode: SortMode = SortMode.NAME
var _sort_asc: bool = true

@onready var _grid: GridContainer = %Grid
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

	_update_columns()
	_load_prefs()

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

func _refresh_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()

	if _subfolders.is_empty() and _files.is_empty():
		_status_label.text = "This folder contains no media files or subfolders."
		_status_label.visible = true
		return

	_status_label.visible = false
	_selected_index = -1

	for path in _subfolders:
		var item := _make_folder_item(path)
		_grid.add_child(item)
		var idx := _grid.get_child_count() - 1
		item.focus_entered.connect(func() -> void: _selected_index = idx)
	for i in _files.size():
		var item := _make_file_thumb(i)
		_grid.add_child(item)
		var idx := _grid.get_child_count() - 1
		item.focus_entered.connect(func() -> void: _selected_index = idx)

	_update_columns()


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
		var tex_rect := TextureRect.new()
		tex_rect.custom_minimum_size = Vector2(tw - 8, ti)
		tex_rect.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		vbox.add_child(tex_rect)
		_load_thumb_deferred.call_deferred(path, tex_rect, tw, ti)

	var name_lbl := Label.new()
	name_lbl.text = path.get_file()
	name_lbl.clip_text = true
	name_lbl.custom_minimum_size.x = tw - 8
	name_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(name_lbl)

	return btn


func _load_thumb_deferred(path: String, tex_rect: TextureRect, w: int, h: int) -> void:
	if not is_instance_valid(tex_rect):
		return
	var img := Image.load_from_file(path)
	if img and is_instance_valid(tex_rect):
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
		tex_rect.texture = ImageTexture.create_from_image(img)


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
	_refresh_grid()
	_save_prefs()


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


func _make_file_cmp() -> Callable:
	match _sort_mode:
		SortMode.MODIFIED:
			return func(a, b): return FileAccess.get_modified_time(a) < FileAccess.get_modified_time(b)
		SortMode.SIZE:
			return func(a, b):
				var fa := FileAccess.open(a, FileAccess.READ)
				var fb := FileAccess.open(b, FileAccess.READ)
				var sa := fa.get_length() if fa else 0
				var sb := fb.get_length() if fb else 0
				return sa < sb
		SortMode.TYPE:
			return func(a, b):
				var ea: String = a.get_extension().to_lower()
				var eb: String = b.get_extension().to_lower()
				return ea < eb if ea != eb else a.get_file().to_lower() < b.get_file().to_lower()
		_:
			return func(a, b): return a.get_file().to_lower() < b.get_file().to_lower()


func _select_grid_item(index: int) -> void:
	var count := _grid.get_child_count()
	if count == 0:
		return
	_selected_index = clampi(index, 0, count - 1)
	var btn := _grid.get_child(_selected_index) as Button
	if btn:
		btn.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F6 or (event.keycode == KEY_L and event.ctrl_pressed):
			_enter_edit_mode()
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
			var count := _grid.get_child_count()
			var cur := _selected_index if _selected_index >= 0 else 0
			match event.keycode:
				KEY_LEFT:
					_select_grid_item(cur - 1)
					get_viewport().set_input_as_handled()
				KEY_RIGHT:
					_select_grid_item(cur + 1)
					get_viewport().set_input_as_handled()
				KEY_UP:
					_select_grid_item(cur - _grid.columns)
					get_viewport().set_input_as_handled()
				KEY_DOWN:
					_select_grid_item(cur + _grid.columns)
					get_viewport().set_input_as_handled()
				KEY_HOME:
					_select_grid_item(0)
					get_viewport().set_input_as_handled()
				KEY_END:
					_select_grid_item(count - 1)
					get_viewport().set_input_as_handled()
				KEY_ENTER, KEY_KP_ENTER:
					if _selected_index >= 0 and count > 0:
						var btn := _grid.get_child(_selected_index) as Button
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
	var collected: Array[String] = []
	var first_folder := ""

	for path in paths:
		if FileAccess.file_exists(path):
			var ext := path.get_extension().to_lower()
			if ext in IMAGE_EXT or ext in VIDEO_EXT:
				collected.append(path)
				if first_folder == "":
					first_folder = path.get_base_dir()
		else:
			# Treat as directory
			_navigate_to(path)
			return   # navigate_to handles everything; done

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
		_status_label.visible = false
		for c in _grid.get_children():
			c.queue_free()
		for i in _files.size():
			_grid.add_child(_make_file_thumb(i))
		_update_columns()


# ──────────────────────────── Layout ───────────────────────────────

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_columns()


func _update_columns() -> void:
	if not is_instance_valid(_grid):
		return
	var w := size.x - 56.0
	_grid.columns = max(1, int(w / (_tw() + 10)))
