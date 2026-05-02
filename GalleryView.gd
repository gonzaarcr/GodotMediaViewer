## Gallery grid – browse local media with in-app folder navigation.
extends Control

signal open_file(path: String, all_files: Array)

const IMAGE_EXT := ["png", "jpg", "jpeg", "bmp", "webp", "tga", "svg"]
const VIDEO_EXT := ["mp4", "webm", "ogv", "avi", "mkv", "mov"]
const THUMB_W   := 168
const THUMB_H   := 148
const THUMB_IMG := 128

var _current_folder: String = ""
var _files: Array[String] = []       # media files in current folder
var _subfolders: Array[String] = []  # subdirectory paths in current folder

var _grid: GridContainer
var _scroll: ScrollContainer
var _status_label: Label
var _breadcrumb_bar: HBoxContainer
var _up_btn: Button


# ──────────────────────────── Setup ────────────────────────────────

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_update_columns()

	var win := get_window()
	if win:
		win.files_dropped.connect(_on_files_dropped)

	# Open Downloads by default; fall back to home directory.
	var dl := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if dl != "" and DirAccess.dir_exists_absolute(dl):
		_navigate_to(dl)
	else:
		var home := OS.get_environment("HOME")
		if home != "":
			_navigate_to(home)


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color("#181820")
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 0)
	add_child(vbox)

	vbox.add_child(_build_header())
	vbox.add_child(_build_nav_bar())
	vbox.add_child(HSeparator.new())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_scroll)

	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	_scroll.add_child(pad)

	_grid = GridContainer.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	pad.add_child(_grid)

	# Overlay shown when a folder is empty or on first launch.
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_status_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_status_label.offset_top = 108  # below header (54) + nav bar (50) + separator (4)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(_status_label)


func _build_header() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 54

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	panel.add_child(hbox)

	_pad(hbox, 8)

	var title := Label.new()
	title.text = "Gallery Viewer"
	title.add_theme_font_size_override("font_size", 17)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	var open_files_btn := Button.new()
	open_files_btn.text = "  Open File(s)  "
	open_files_btn.custom_minimum_size.y = 36
	open_files_btn.pressed.connect(_show_file_dialog)
	hbox.add_child(open_files_btn)

	var open_folder_btn := Button.new()
	open_folder_btn.text = "  Open Folder  "
	open_folder_btn.custom_minimum_size.y = 36
	open_folder_btn.pressed.connect(_show_folder_dialog)
	hbox.add_child(open_folder_btn)

	_pad(hbox, 8)
	return panel


func _build_nav_bar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 36

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	panel.add_child(hbox)

	_pad(hbox, 4)

	_up_btn = Button.new()
	_up_btn.text = "↑ Up"
	_up_btn.tooltip_text = "Parent folder"
	_up_btn.disabled = true
	_up_btn.pressed.connect(_go_up)
	hbox.add_child(_up_btn)

	hbox.add_child(VSeparator.new())

	# Scrollable breadcrumb row (no vertical scroll)
	var crumb_scroll := ScrollContainer.new()
	crumb_scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	crumb_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	crumb_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	hbox.add_child(crumb_scroll)

	_breadcrumb_bar = HBoxContainer.new()
	_breadcrumb_bar.add_theme_constant_override("separation", 0)
	crumb_scroll.add_child(_breadcrumb_bar)

	_pad(hbox, 4)
	return panel


func _pad(parent: Control, px: int) -> void:
	var c := Control.new()
	c.custom_minimum_size.x = px
	parent.add_child(c)


# ──────────────────────────── Navigation ───────────────────────────

func _navigate_to(folder: String) -> void:
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

	_subfolders.sort()
	_files.sort()

	_up_btn.disabled = (folder.get_base_dir() == folder)
	_update_breadcrumbs()
	_refresh_grid()


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


# ──────────────────────────── Grid ─────────────────────────────────

func _refresh_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()

	if _subfolders.is_empty() and _files.is_empty():
		_status_label.text = "This folder contains no media files or subfolders."
		_status_label.visible = true
		return

	_status_label.visible = false

	for path in _subfolders:
		_grid.add_child(_make_folder_item(path))
	for i in _files.size():
		_grid.add_child(_make_file_thumb(i))

	_update_columns()


func _make_folder_item(path: String) -> Control:
	var folder_name := path.get_file()

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(THUMB_W, THUMB_H)
	btn.tooltip_text = folder_name
	btn.pressed.connect(func() -> void: _navigate_to(path))

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn.add_child(vbox)

	var bg := ColorRect.new()
	bg.custom_minimum_size = Vector2(THUMB_W - 8, THUMB_IMG)
	bg.color = Color("#252515")
	vbox.add_child(bg)

	var icon := Label.new()
	icon.text = "📁"
	icon.add_theme_font_size_override("font_size", 52)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = folder_name
	name_lbl.clip_text = true
	name_lbl.custom_minimum_size.x = THUMB_W - 8
	name_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(name_lbl)

	return btn


func _make_file_thumb(index: int) -> Control:
	var path := _files[index]
	var is_video := path.get_extension().to_lower() in VIDEO_EXT

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(THUMB_W, THUMB_H)
	btn.tooltip_text = path.get_file()
	btn.pressed.connect(func() -> void: open_file.emit(path, _files))

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn.add_child(vbox)

	if is_video:
		var placeholder := ColorRect.new()
		placeholder.custom_minimum_size = Vector2(THUMB_W - 8, THUMB_IMG)
		placeholder.color = Color("#1a2040")
		vbox.add_child(placeholder)

		var lbl := Label.new()
		lbl.text = "▶  VIDEO"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		placeholder.add_child(lbl)
	else:
		var tex_rect := TextureRect.new()
		tex_rect.custom_minimum_size = Vector2(THUMB_W - 8, THUMB_IMG)
		tex_rect.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		vbox.add_child(tex_rect)
		_load_thumb_deferred.call_deferred(path, tex_rect)

	var name_lbl := Label.new()
	name_lbl.text = path.get_file()
	name_lbl.clip_text = true
	name_lbl.custom_minimum_size.x = THUMB_W - 8
	name_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(name_lbl)

	return btn


func _load_thumb_deferred(path: String, tex_rect: TextureRect) -> void:
	if not is_instance_valid(tex_rect):
		return
	var img := Image.load_from_file(path)
	if img and is_instance_valid(tex_rect):
		img.resize(THUMB_W, THUMB_IMG, Image.INTERPOLATE_BILINEAR)
		tex_rect.texture = ImageTexture.create_from_image(img)


# ──────────────────────────── Dialogs ──────────────────────────────

func _show_file_dialog() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dlg.access    = FileDialog.ACCESS_FILESYSTEM
	dlg.title     = "Select Media Files"
	dlg.filters   = PackedStringArray([
		"*.png,*.jpg,*.jpeg,*.bmp,*.webp,*.tga,*.svg,*.mp4,*.webm,*.ogv,*.avi,*.mkv,*.mov ; All Media",
		"*.png,*.jpg,*.jpeg,*.bmp,*.webp,*.tga,*.svg ; Images",
		"*.mp4,*.webm,*.ogv,*.avi,*.mkv,*.mov ; Videos",
	])
	if _current_folder != "":
		dlg.current_dir = _current_folder
	dlg.files_selected.connect(func(paths: PackedStringArray) -> void:
		dlg.queue_free()
		var collected: Array[String] = []
		for path in paths:
			var ext := path.get_extension().to_lower()
			if ext in IMAGE_EXT or ext in VIDEO_EXT:
				collected.append(path)
		if collected.is_empty():
			return
		collected.sort()
		# Show the files without changing folder navigation state.
		_files = collected
		_subfolders.clear()
		_status_label.visible = false
		for c in _grid.get_children():
			c.queue_free()
		for i in _files.size():
			_grid.add_child(_make_file_thumb(i))
		_update_columns()
	)
	add_child(dlg)
	dlg.popup_centered(Vector2i(900, 650))


func _show_folder_dialog() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dlg.access    = FileDialog.ACCESS_FILESYSTEM
	dlg.title     = "Select Folder"
	if _current_folder != "":
		dlg.current_dir = _current_folder
	dlg.dir_selected.connect(func(path: String) -> void:
		dlg.queue_free()
		_navigate_to(path)
	)
	add_child(dlg)
	dlg.popup_centered(Vector2i(900, 650))


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
	_grid.columns = max(1, int(w / (THUMB_W + 10)))
