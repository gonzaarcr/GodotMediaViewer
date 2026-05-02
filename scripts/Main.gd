extends Control

var _gallery: Control
var _viewer: Control

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_gallery = preload("res://scenes/GalleryView.tscn").instantiate()
	add_child(_gallery)

	_viewer = preload("res://scenes/MediaViewer.tscn").instantiate()
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
