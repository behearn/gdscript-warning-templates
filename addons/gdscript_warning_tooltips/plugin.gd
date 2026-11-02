@tool
extends EditorPlugin

const ADDED_GUTTER_NAME := "gdscript_warning"
const INFO_GUTTER_NAME := "connection_gutter"
const META_LINES := &"gdscript_warning_lines"
const META_TOOLTIPS := &"gdscript_warning_tooltips"
const META_ICON := &"gdscript_warning_icon"
const TOOLTIP_WIDTH := 380.0

var _popup: PanelContainer
var _popup_label: Label
var _hover_timer: Timer
var _hooked: Dictionary = {}
var _hover_code_edit: CodeEdit
var _hover_line := -1
var _hover_local_pos := Vector2.ZERO
var _exit_check_pending := false
var _popup_armed := false


func _enter_tree() -> void:
	_setup_popup()
	_setup_timer()
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null and not script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
		script_editor.editor_script_changed.connect(_on_editor_script_changed)
	var settings := EditorInterface.get_editor_settings()
	if settings != null and not settings.settings_changed.is_connected(_on_editor_settings_changed):
		settings.settings_changed.connect(_on_editor_settings_changed)
	_hook_open_editors.call_deferred()


func _exit_tree() -> void:
	_clear_hover()
	if _popup != null and is_instance_valid(_popup):
		_popup.queue_free()
	_popup = null
	_popup_label = null
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null and script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
		script_editor.editor_script_changed.disconnect(_on_editor_script_changed)
	var settings := EditorInterface.get_editor_settings()
	if settings != null and settings.settings_changed.is_connected(_on_editor_settings_changed):
		settings.settings_changed.disconnect(_on_editor_settings_changed)
	for editor_id in _hooked.keys():
		var editor := instance_from_id(int(editor_id)) as ScriptEditorBase
		if editor != null:
			_unhook_editor(editor)
	_hooked.clear()


func _setup_popup() -> void:
	# Drawn inside the editor. A native popup window is positioned in screen space
	# and ends up a gutter left of the icon.
	_popup = PanelContainer.new()
	_popup.name = "GDScriptWarningTooltip"
	_popup.visible = false
	_popup.mouse_filter = Control.MOUSE_FILTER_STOP
	_popup.focus_mode = Control.FOCUS_NONE
	_popup.z_as_relative = false
	_popup.z_index = 128
	_popup.mouse_entered.connect(_on_popup_mouse_entered)
	_popup.mouse_exited.connect(_on_popup_mouse_exited)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	_popup.add_child(margin)
	_popup_label = Label.new()
	_popup_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_popup_label.custom_minimum_size = Vector2(TOOLTIP_WIDTH, 0)
	_popup_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_popup_label)
	var parent := EditorInterface.get_base_control()
	if parent != null:
		parent.add_child(_popup)
	else:
		add_child(_popup)
	_apply_tooltip_theme()


func _apply_tooltip_theme() -> void:
	var base := EditorInterface.get_base_control()
	if base == null or _popup == null:
		return
	if base.has_theme_stylebox("panel", "TooltipPanel"):
		var style := base.get_theme_stylebox("panel", "TooltipPanel")
		if style != null:
			_popup.add_theme_stylebox_override("panel", style)
	if base.has_theme_color("font_color", "TooltipLabel"):
		_popup_label.add_theme_color_override("font_color", base.get_theme_color("font_color", "TooltipLabel"))
	if base.has_theme_font("font", "TooltipLabel"):
		_popup_label.add_theme_font_override("font", base.get_theme_font("font", "TooltipLabel"))
	if base.has_theme_font_size("font_size", "TooltipLabel"):
		_popup_label.add_theme_font_size_override("font_size", base.get_theme_font_size("font_size", "TooltipLabel"))


func _setup_timer() -> void:
	_hover_timer = Timer.new()
	_hover_timer.one_shot = true
	_hover_timer.timeout.connect(_on_hover_timeout)
	add_child(_hover_timer)


func _on_editor_script_changed(_script: Variant) -> void:
	_hook_open_editors.call_deferred()


func _on_editor_settings_changed() -> void:
	for editor_id in _hooked.keys():
		var editor := instance_from_id(int(editor_id)) as ScriptEditorBase
		if editor != null:
			_refresh_editor(editor)


func _hook_open_editors() -> void:
	if not is_inside_tree():
		return
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return
	for editor in script_editor.get_open_script_editors():
		_hook_editor(editor as ScriptEditorBase)


func _hook_editor(editor: ScriptEditorBase) -> void:
	if editor == null or not is_instance_valid(editor):
		return
	var editor_id := editor.get_instance_id()
	if _hooked.has(editor_id):
		return
	var code_edit := editor.get_base_editor() as CodeEdit
	if code_edit == null:
		return
	var code_text := code_edit.get_parent()
	if code_text == null or not code_text.has_signal("validate_script"):
		return
	if _warnings_label(code_edit) == null:
		return

	var validate_cb := _on_validate_script.bind(editor)
	var gui_cb := _on_code_gui_input.bind(code_edit)
	var exit_cb := _on_code_mouse_exited.bind(code_edit)
	var gutter_cb := _on_gutter_clicked.bind(code_edit)
	var closing_cb := _on_editor_exiting.bind(editor)
	code_text.connect("validate_script", validate_cb)
	code_edit.connect("gui_input", gui_cb)
	code_edit.connect("mouse_exited", exit_cb)
	code_edit.connect("gutter_clicked", gutter_cb)
	editor.tree_exiting.connect(closing_cb)

	_hooked[editor_id] = {
		"code_edit": code_edit,
		"code_text": code_text,
		"validate_cb": validate_cb,
		"gui_cb": gui_cb,
		"exit_cb": exit_cb,
		"gutter_cb": gutter_cb,
		"closing_cb": closing_cb,
	}
	remove_added_gutter(code_edit)
	_refresh_editor.call_deferred(editor)


func _on_editor_exiting(editor: ScriptEditorBase) -> void:
	_unhook_editor(editor)


func _unhook_editor(editor: ScriptEditorBase) -> void:
	if editor == null or not is_instance_valid(editor):
		return
	var editor_id := editor.get_instance_id()
	if not _hooked.has(editor_id):
		return
	var state: Dictionary = _hooked[editor_id]
	_hooked.erase(editor_id)

	var code_edit: CodeEdit = state.get("code_edit")
	var code_text: Node = state.get("code_text")
	_disconnect(code_text, "validate_script", state.get("validate_cb"))
	_disconnect(code_edit, "gui_input", state.get("gui_cb"))
	_disconnect(code_edit, "mouse_exited", state.get("exit_cb"))
	_disconnect(code_edit, "gutter_clicked", state.get("gutter_cb"))
	_disconnect(editor, "tree_exiting", state.get("closing_cb"))

	if is_instance_valid(code_edit):
		if _hover_code_edit == code_edit:
			_clear_hover()
		_clear_warning_marks(code_edit)


func _disconnect(obj: Object, signal_name: String, callback: Variant) -> void:
	if obj == null or not is_instance_valid(obj) or not (callback is Callable):
		return
	if not obj.has_signal(signal_name):
		return
	var callable := callback as Callable
	if obj.is_connected(signal_name, callable):
		obj.disconnect(signal_name, callable)


func _on_validate_script(editor: ScriptEditorBase) -> void:
	# Deferred so this runs after ScriptTextEditor has rebuilt the warnings panel.
	_refresh_editor.call_deferred(editor)


func _refresh_editor(editor: ScriptEditorBase) -> void:
	if editor == null or not is_instance_valid(editor):
		return
	var code_edit := editor.get_base_editor() as CodeEdit
	if code_edit == null:
		return
	remove_added_gutter(code_edit)
	var gutter := info_gutter_index(code_edit)
	if gutter >= 0:
		apply_warning_icons(code_edit, gutter, parse_warning_panel(_warnings_text(code_edit)), _warning_icon())
	if _hover_code_edit == code_edit and _popup != null and _popup.visible:
		var text := _tooltip_for(code_edit, _hover_line)
		if text.is_empty():
			_clear_hover()
		else:
			_popup_label.text = text
			_popup.reset_size()


func _warnings_label(code_edit: CodeEdit) -> RichTextLabel:
	var code_text := code_edit.get_parent()
	if code_text == null:
		return null
	var split := code_text.get_parent()
	if split == null:
		return null
	for child in split.get_children():
		if child is RichTextLabel:
			return child as RichTextLabel
	return null


func _warnings_text(code_edit: CodeEdit) -> String:
	var chunks: PackedStringArray = []
	var code_text := code_edit.get_parent()
	if code_text == null or code_text.get_parent() == null:
		return ""
	for child in code_text.get_parent().get_children():
		if child is RichTextLabel:
			chunks.append((child as RichTextLabel).get_parsed_text())
	return "\n".join(chunks)


func _gutter_index(code_edit: CodeEdit) -> int:
	return info_gutter_index(code_edit)


func _clear_warning_marks(code_edit: CodeEdit) -> void:
	var gutter := info_gutter_index(code_edit)
	if gutter >= 0:
		clear_warning_icons(code_edit, gutter)
	remove_added_gutter(code_edit)


static func _meta_icon(code_edit: CodeEdit) -> Texture2D:
	if not code_edit.has_meta(META_ICON):
		return null
	return code_edit.get_meta(META_ICON)


static func info_gutter_index(code_edit: CodeEdit) -> int:
	for i in code_edit.get_gutter_count():
		if code_edit.get_gutter_name(i) == INFO_GUTTER_NAME:
			return i
	return -1


static func remove_added_gutter(code_edit: CodeEdit) -> void:
	for i in range(code_edit.get_gutter_count() - 1, -1, -1):
		if code_edit.get_gutter_name(i) == ADDED_GUTTER_NAME:
			code_edit.remove_gutter(i)


static func apply_warning_icons(code_edit: CodeEdit, gutter: int, warnings: Dictionary, icon: Texture2D) -> void:
	var previous_icon: Texture2D = _meta_icon(code_edit)
	var previous: Array = code_edit.get_meta(META_LINES, []) if code_edit.has_meta(META_LINES) else []
	for line in previous:
		var line_index := int(line)
		if line_index < 0 or line_index >= code_edit.get_line_count():
			continue
		var current := code_edit.get_line_gutter_icon(line_index, gutter)
		if current != null and (current == icon or current == previous_icon):
			code_edit.set_line_gutter_icon(line_index, gutter, null)

	var tooltips := {}
	var lines: Array[int] = []
	for line in warnings.keys():
		var line_index := int(line)
		if line_index < 0 or line_index >= code_edit.get_line_count():
			continue
		var messages: Array = warnings[line]
		tooltips[line_index] = "\n".join(messages)
		lines.append(line_index)
		var current := code_edit.get_line_gutter_icon(line_index, gutter)
		if icon != null and (current == null or current == icon or current == previous_icon):
			code_edit.set_line_gutter_icon(line_index, gutter, icon)
	code_edit.set_meta(META_LINES, lines)
	code_edit.set_meta(META_TOOLTIPS, tooltips)
	code_edit.set_meta(META_ICON, icon)


static func clear_warning_icons(code_edit: CodeEdit, gutter: int) -> void:
	apply_warning_icons(code_edit, gutter, {}, _meta_icon(code_edit))
	if code_edit.has_meta(META_LINES):
		code_edit.remove_meta(META_LINES)
	if code_edit.has_meta(META_TOOLTIPS):
		code_edit.remove_meta(META_TOOLTIPS)
	if code_edit.has_meta(META_ICON):
		code_edit.remove_meta(META_ICON)


func _warning_icon() -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return null
	if theme.has_icon("NodeWarning", "EditorIcons"):
		return theme.get_icon("NodeWarning", "EditorIcons")
	if theme.has_icon("StatusWarning", "EditorIcons"):
		return theme.get_icon("StatusWarning", "EditorIcons")
	return null


func _tooltip_for(code_edit: CodeEdit, line: int) -> String:
	if line < 0 or line >= code_edit.get_line_count():
		return ""
	var tooltips: Dictionary = code_edit.get_meta(META_TOOLTIPS, {})
	if not tooltips.has(line):
		return ""
	return str(tooltips[line])


func _on_code_gui_input(event: InputEvent, code_edit: CodeEdit) -> void:
	if event is InputEventMouseMotion:
		_update_hover(code_edit, (event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_show_warning_now(code_edit, button.position)
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP or button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_update_hover.call_deferred(code_edit, code_edit.get_local_mouse_position())


func _on_gutter_clicked(line: int, gutter: int, code_edit: CodeEdit) -> void:
	# The editor's own hit test. This is the cell the warning icon is drawn in,
	# including when our hover math would land in the padding to its left.
	if not is_instance_valid(code_edit) or gutter != info_gutter_index(code_edit):
		return
	if not _line_shows_warning_icon(code_edit, line):
		return
	var text := _tooltip_for(code_edit, line)
	if text.is_empty():
		return
	_reveal_tooltip(code_edit, line, code_edit.get_local_mouse_position(), text)


func _show_warning_now(code_edit: CodeEdit, local_position: Vector2) -> void:
	if not is_instance_valid(code_edit):
		return
	var hit := gutter_at_position(code_edit, local_position)
	var gutter := _gutter_index(code_edit)
	if hit.x != gutter or not _line_shows_warning_icon(code_edit, hit.y):
		return
	var text := _tooltip_for(code_edit, hit.y)
	if text.is_empty():
		return
	_reveal_tooltip(code_edit, hit.y, local_position, text)


func _reveal_tooltip(code_edit: CodeEdit, line: int, local_position: Vector2, text: String) -> void:
	if _hover_timer != null:
		_hover_timer.stop()
	_hover_code_edit = code_edit
	_hover_line = line
	_hover_local_pos = local_position
	_present_tooltip(code_edit, local_position, text)


func _line_shows_warning_icon(code_edit: CodeEdit, line: int) -> bool:
	var gutter := info_gutter_index(code_edit)
	if gutter < 0 or line < 0 or line >= code_edit.get_line_count():
		return false
	var warning_icon := _meta_icon(code_edit)
	if warning_icon == null:
		return false
	return code_edit.get_line_gutter_icon(line, gutter) == warning_icon


func _update_hover(code_edit: CodeEdit, local_position: Vector2) -> void:
	if not is_instance_valid(code_edit):
		_clear_hover()
		return
	var hit := gutter_at_position(code_edit, local_position)
	var gutter := _gutter_index(code_edit)
	var text := ""
	if hit.x == gutter and hit.y >= 0:
		text = _tooltip_for(code_edit, hit.y)
	if text.is_empty():
		if _hover_code_edit == code_edit:
			_clear_hover()
		return

	var same_target := _hover_code_edit == code_edit and _hover_line == hit.y
	_hover_code_edit = code_edit
	_hover_line = hit.y
	_hover_local_pos = local_position
	if _popup.visible and same_target:
		return
	if _popup.visible:
		_present_tooltip(code_edit, local_position, text)
		return
	if not same_target:
		_hover_timer.start(_tooltip_delay())


func _on_code_mouse_exited(code_edit: CodeEdit) -> void:
	if _hover_code_edit != code_edit:
		return
	_exit_check_pending = true
	_confirm_hover_exit.call_deferred()


func _confirm_hover_exit() -> void:
	if not _exit_check_pending:
		return
	_exit_check_pending = false
	if _pointer_over_popup():
		return
	_clear_hover()


func _on_popup_mouse_entered() -> void:
	_popup_armed = true


func _on_popup_mouse_exited() -> void:
	if not _popup_armed:
		return
	_popup_armed = false
	if _pointer_over_popup():
		return
	if _hover_code_edit != null and is_instance_valid(_hover_code_edit):
		var hit := gutter_at_position(_hover_code_edit, _hover_code_edit.get_local_mouse_position())
		if hit.x == _gutter_index(_hover_code_edit) and hit.y == _hover_line:
			return
	_clear_hover()


func _on_hover_timeout() -> void:
	if _hover_code_edit == null or not is_instance_valid(_hover_code_edit):
		_clear_hover()
		return
	var text := _tooltip_for(_hover_code_edit, _hover_line)
	if text.is_empty():
		_clear_hover()
		return
	_present_tooltip(_hover_code_edit, _hover_local_pos, text)


func _present_tooltip(code_edit: CodeEdit, local_pos: Vector2, text: String) -> void:
	if _popup == null or _popup_label == null:
		return
	_popup_label.text = text
	var label_min := _popup_label.get_minimum_size()
	var extra := Vector2(16.0, 12.0)
	var style := _popup.get_theme_stylebox("panel")
	if style != null:
		extra.x += style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT)
		extra.y += style.get_margin(SIDE_TOP) + style.get_margin(SIDE_BOTTOM)
	var popup_size := Vector2(maxf(label_min.x + extra.x, TOOLTIP_WIDTH), label_min.y + extra.y)
	_popup.custom_minimum_size = popup_size
	_popup.size = popup_size
	var gutter := _gutter_index(code_edit)
	# Sit just to the right of the icon. The pointer can be in the padding
	# between the breakpoint column and the glyph; don't anchor there.
	var anchor := Vector2(gutter_right_x(code_edit, gutter) + 6.0, local_pos.y)
	anchor.x = maxf(anchor.x, local_pos.x + 14.0)
	var pos := _to_popup_position(code_edit, anchor)
	var parent := _popup.get_parent() as Control
	var bounds := parent.size if parent != null else code_edit.get_viewport_rect().size
	if pos.x + popup_size.x > bounds.x:
		var left_anchor := Vector2(gutter_left_x(code_edit, gutter) - 6.0, local_pos.y)
		pos.x = _to_popup_position(code_edit, left_anchor).x - popup_size.x
	if pos.y + popup_size.y > bounds.y:
		pos.y = maxf(0.0, bounds.y - popup_size.y)
	pos.x = maxf(0.0, pos.x)
	pos.y = maxf(0.0, pos.y)
	_popup.position = pos
	_popup.show()
	_popup.move_to_front()


func _clear_hover() -> void:
	_hover_code_edit = null
	_hover_line = -1
	_hover_local_pos = Vector2.ZERO
	_exit_check_pending = false
	_popup_armed = false
	if _hover_timer != null:
		_hover_timer.stop()
	if _popup != null and _popup.visible:
		_popup.hide()


func _pointer_over_popup() -> bool:
	if _popup == null or not _popup.visible:
		return false
	return _popup.get_global_rect().grow(16.0).has_point(_popup.get_global_mouse_position())


func _tooltip_delay() -> float:
	if ProjectSettings.has_setting("gui/timers/tooltip_delay_sec"):
		return maxf(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec")), 0.0)
	return 0.5


func _to_popup_position(code_edit: CodeEdit, local_pos: Vector2) -> Vector2:
	var canvas_pos: Vector2 = code_edit.get_global_transform_with_canvas() * local_pos
	var parent := _popup.get_parent() as Control
	if parent == null:
		return canvas_pos
	return parent.get_global_transform_with_canvas().affine_inverse() * canvas_pos


static func gutter_right_x(code_edit: CodeEdit, gutter: int) -> float:
	var left := _content_left(code_edit)
	for i in code_edit.get_gutter_count():
		if not code_edit.is_gutter_drawn(i) or code_edit.get_gutter_width(i) <= 0:
			continue
		var width := float(code_edit.get_gutter_width(i))
		if i == gutter:
			return left + width
		left += width
	return left


static func gutter_left_x(code_edit: CodeEdit, gutter: int) -> float:
	var right := gutter_right_x(code_edit, gutter)
	if gutter < 0 or gutter >= code_edit.get_gutter_count():
		return right
	if not code_edit.is_gutter_drawn(gutter) or code_edit.get_gutter_width(gutter) <= 0:
		return right
	return right - float(code_edit.get_gutter_width(gutter))


static func gutter_at_position(code_edit: CodeEdit, position: Vector2) -> Vector2i:
	var pos := position
	if code_edit.is_layout_rtl():
		pos.x = code_edit.size.x - pos.x
	var left := _content_left(code_edit)
	if pos.x > left + float(code_edit.get_total_gutter_width()):
		return Vector2i(-1, -1)
	var line := code_edit.get_line_column_at_pos(Vector2i(int(pos.x), int(pos.y)), false).y
	if line < 0:
		return Vector2i(-1, -1)
	for i in code_edit.get_gutter_count():
		if not code_edit.is_gutter_drawn(i) or code_edit.get_gutter_width(i) <= 0:
			continue
		var width := float(code_edit.get_gutter_width(i))
		if pos.x >= left and pos.x < left + width:
			return Vector2i(i, line)
		left += width
	return Vector2i(-1, -1)


static func _content_left(code_edit: CodeEdit) -> float:
	# TextEdit places gutters from the normal or read-only style. The focus
	# style is empty in the editor theme, which shifts the hit target left
	# into the gap between the breakpoint column and the warning icon.
	var style_name := "normal" if code_edit.editable else "read_only"
	var style := code_edit.get_theme_stylebox(style_name)
	if style == null:
		return 0.0
	return ceil(style.get_margin(SIDE_LEFT))


static func parse_warning_panel(text: String) -> Dictionary:
	if text.is_empty():
		return {}
	var translated := TranslationServer.translate("Line %d (%s):")
	var parsed := _parse_with_template(text, translated)
	if parsed.is_empty() and translated != "Line %d (%s):":
		parsed = _parse_with_template(text, "Line %d (%s):")
	return parsed


static func _parse_with_template(text: String, template: String) -> Dictionary:
	var order := _placeholder_order(template)
	var line_group := order.find("d")
	var code_group := order.find("s")
	if line_group < 0 or code_group < 0:
		return {}
	var regex := RegEx.new()
	if regex.compile(_pattern_from_template(template)) != OK:
		return {}
	var matches := regex.search_all(text)
	var result := {}
	for index in matches.size():
		var match := matches[index]
		var line_number := int(match.get_string(line_group + 1))
		if line_number <= 0:
			continue
		var message_end := text.length()
		if index + 1 < matches.size():
			message_end = matches[index + 1].get_start()
		var message := _clean_message(text.substr(match.get_end(), message_end - match.get_end()))
		var header := match.get_string(0).strip_edges()
		var entry := header if message.is_empty() else "%s %s" % [header, message]
		var line_index := line_number - 1
		var messages: Array = result.get(line_index, [])
		messages.append(entry)
		result[line_index] = messages
	return result


static func _clean_message(raw: String) -> String:
	var message := raw.strip_edges()
	var ignores: PackedStringArray = [
		TranslationServer.translate("[Ignore]").strip_edges(),
		"[Ignore]",
	]
	var changed := true
	while changed:
		changed = false
		for ignore in ignores:
			if ignore.is_empty():
				continue
			if message.ends_with(ignore):
				message = message.substr(0, message.length() - ignore.length()).strip_edges()
				changed = true
	return message


static func _placeholder_order(template: String) -> PackedStringArray:
	var order: PackedStringArray = []
	var index := 0
	while index < template.length():
		if template[index] != "%":
			index += 1
			continue
		var rest := template.substr(index)
		if rest.begins_with("%%"):
			index += 2
			continue
		if rest.begins_with("%1$d"):
			order.append("d")
			index += 4
		elif rest.begins_with("%2$s"):
			order.append("s")
			index += 4
		elif rest.begins_with("%d"):
			order.append("d")
			index += 2
		elif rest.begins_with("%s"):
			order.append("s")
			index += 2
		else:
			index += 1
	return order


static func _pattern_from_template(template: String) -> String:
	var escaped := _regex_escape(template)
	escaped = escaped.replace("%1\\$d", "(\\d+)")
	escaped = escaped.replace("%2\\$s", "([A-Z0-9_]+)")
	escaped = escaped.replace("%d", "(\\d+)")
	escaped = escaped.replace("%s", "([A-Z0-9_]+)")
	return escaped


static func _regex_escape(text: String) -> String:
	var out := ""
	const SPECIAL := "\\.^$|?*+()[]{}"
	for index in text.length():
		var ch := text[index]
		if SPECIAL.contains(ch):
			out += "\\" + ch
		else:
			out += ch
	return out
