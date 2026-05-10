## Virtualized grid that only instantiates items currently in its parent
## ScrollContainer's visible band (plus a small overscan).
##
## Usage:
##   var vg: VirtualGrid = $Path/To/Grid
##   vg.configure(
##       func() -> int: return my_data.size(),
##       func(idx: int) -> Control: return _build_item_for(my_data[idx]),
##   )
##   vg.reload()                    # after data changes
##   vg.set_item_size(w, h)         # e.g. zoom changed; preserves scroll
##   vg.select_index(i)             # keyboard nav: scroll into view + focus
##
## The component must live inside a ScrollContainer (any depth). Items are
## positioned manually at (col * col_step, row * row_step); the host node's
## custom_minimum_size.y is set to the full virtual height so the
## ScrollContainer's scrollbar reflects the entire dataset.
class_name VirtualGrid
extends Control

signal selection_changed(idx: int)

@export var item_width: int = 168
@export var item_height: int = 148
@export var spacing: int = 10
@export var overscan_rows: int = 2

var _scroll: ScrollContainer
var _count_provider: Callable
var _factory: Callable

var _columns: int = 1
var _row_step: int = 0
var _col_step: int = 0
var _visible: Dictionary = {}            # flat index → Control
var _pinned: Control = null              # selection kept alive when off-screen
var _selected_index: int = -1


func _ready() -> void:
	_scroll = _find_scroll_ancestor()
	if _scroll:
		_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _update_window())
	else:
		push_warning("VirtualGrid has no ScrollContainer ancestor — virtualization disabled.")
	resized.connect(_relayout_preserve_top)


# ──────────────────────────── Public API ───────────────────────────

func configure(count_provider: Callable, factory: Callable) -> void:
	_count_provider = count_provider
	_factory = factory


# Drop all items, reset selection, scroll to top, rebuild from scratch.
func reload() -> void:
	_free_all()
	_selected_index = -1
	if _scroll:
		_scroll.scroll_vertical = 0
	_relayout()


# Change item dimensions (e.g. zoom). Items rebuild at the new size while
# the user's scroll position is preserved by item index.
func set_item_size(w: int, h: int) -> void:
	if w == item_width and h == item_height:
		return
	item_width = w
	item_height = h
	var anchor := _top_visible_index()
	_free_all()
	_selected_index = -1
	_relayout()
	_restore_anchor(anchor)


func selected_index() -> int:
	return _selected_index


func get_visible_item(idx: int) -> Control:
	return _visible.get(idx)


func total_count() -> int:
	return int(_count_provider.call()) if _count_provider.is_valid() else 0


func column_count() -> int:
	return _columns


# Move selection. Scrolls the target row into view, then grabs focus on the
# item's Button (if it is one).
func select_index(idx: int) -> void:
	var count := total_count()
	if count == 0 or _row_step <= 0 or _columns <= 0 or not _scroll:
		return
	var clamped := clampi(idx, 0, count - 1)
	var prev := _selected_index
	_selected_index = clamped

	var row := clamped / _columns
	var top: float = _scroll.scroll_vertical
	var view_h: float = _scroll.size.y
	var row_top := row * _row_step
	var row_bot := row_top + _row_step
	if row_top < top:
		_scroll.scroll_vertical = row_top
	elif row_bot > top + view_h:
		_scroll.scroll_vertical = maxi(0, row_bot - view_h)

	_update_window()

	# Drop the previously pinned item if it's now off-screen and no longer selected.
	if prev != clamped and is_instance_valid(_pinned) and not _visible.has(prev):
		_pinned.queue_free()
		_pinned = null

	var item: Control = _visible.get(clamped)
	if item and is_instance_valid(item):
		_pinned = item
		var btn := item as Button
		if btn:
			btn.grab_focus()
	selection_changed.emit(_selected_index)


# ──────────────────────────── Internals ────────────────────────────

func _find_scroll_ancestor() -> ScrollContainer:
	var n: Node = get_parent()
	while n:
		if n is ScrollContainer:
			return n
		n = n.get_parent()
	return null


func _relayout() -> void:
	if not _factory.is_valid():
		return
	_col_step = item_width + spacing
	_row_step = item_height + spacing
	var avail := size.x
	_columns = maxi(1, int((avail + spacing) / _col_step))

	var total := total_count()
	var rows := int(ceil(float(total) / float(_columns))) if total > 0 else 0
	var content_h := rows * _row_step - spacing if rows > 0 else 0
	custom_minimum_size = Vector2(0, maxi(0, content_h))

	# Reposition any items that survived a zoom/resize so they land in the new grid.
	for k in _visible.keys():
		var idx: int = k
		var item: Control = _visible[idx]
		if is_instance_valid(item):
			_position(item, idx)

	_update_window()


func _relayout_preserve_top() -> void:
	var anchor := _top_visible_index()
	_relayout()
	_restore_anchor(anchor)


func _restore_anchor(anchor: int) -> void:
	if anchor < 0 or _row_step <= 0 or _columns <= 0 or not _scroll:
		return
	var row := anchor / _columns
	_scroll.scroll_vertical = row * _row_step
	_update_window()


func _update_window() -> void:
	if _columns <= 0 or _row_step <= 0 or not _scroll or not _factory.is_valid():
		return
	var total := total_count()
	if total == 0:
		_free_all()
		return

	var top: float = _scroll.scroll_vertical
	var view_h: float = _scroll.size.y
	var first_row: int = maxi(0, int(floor(top / float(_row_step))) - overscan_rows)
	var last_row: int = int(ceil((top + view_h) / float(_row_step))) + overscan_rows
	var begin: int = first_row * _columns
	var end: int = mini(total, (last_row + 1) * _columns)

	# Free items that scrolled off, except the pinned selection.
	var to_free: Array[int] = []
	for k in _visible.keys():
		var idx: int = k
		if (idx < begin or idx >= end) and idx != _selected_index:
			to_free.append(idx)
	for idx in to_free:
		var item: Control = _visible[idx]
		if is_instance_valid(item):
			item.queue_free()
		_visible.erase(idx)
		if _pinned == item:
			_pinned = null

	# Spawn newly-visible items.
	for idx in range(begin, end):
		if _visible.has(idx):
			continue
		var item: Control = _factory.call(idx)
		_position(item, idx)
		add_child(item)
		_visible[idx] = item
		var captured := idx
		item.focus_entered.connect(func() -> void:
			_selected_index = captured
			selection_changed.emit(captured)
		)


func _position(item: Control, idx: int) -> void:
	var row := idx / _columns
	var col := idx % _columns
	item.position = Vector2(col * _col_step, row * _row_step)
	item.size = Vector2(item_width, item_height)


func _free_all() -> void:
	for k in _visible.keys():
		var item: Control = _visible[k]
		if is_instance_valid(item):
			item.queue_free()
	_visible.clear()
	_pinned = null


# Smallest visible flat index whose row starts at or below the current scroll
# offset, or -1 if nothing is currently visible.
func _top_visible_index() -> int:
	if _row_step <= 0 or _visible.is_empty() or not _scroll:
		return -1
	var top: float = _scroll.scroll_vertical
	var best := -1
	for k in _visible.keys():
		var idx: int = k
		var row := idx / maxi(1, _columns)
		if row * _row_step >= top - 0.5:
			if best < 0 or idx < best:
				best = idx
	if best < 0:
		for k in _visible.keys():
			var idx: int = k
			if best < 0 or idx < best:
				best = idx
	return best
