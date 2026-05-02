extends Control

var _gallery: Control
var _viewer: Control

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_gallery = preload("res://GalleryView.gd").new()
	_gallery.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_gallery)

	_viewer = preload("res://MediaViewer.gd").new()
	_viewer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewer.visible = false
	add_child(_viewer)

	_gallery.open_file.connect(_on_open_file)
	_viewer.back_pressed.connect(_on_back_pressed)

func _on_open_file(path: String, files: Array) -> void:
	_viewer.open_media(path, files)
	_gallery.visible = false
	_viewer.visible = true

func _on_back_pressed() -> void:
	_viewer.visible = false
	_gallery.visible = true
