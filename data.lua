local ICON = "__base__/graphics/icons/splitter.png"

data:extend({
  {
    type = "selection-tool",
    name = "lbb-balancer-tool",
    icon = ICON,
    icon_size = 64,
    flags = {"only-in-cursor", "not-stackable", "spawnable"},
    hidden = true,
    stack_size = 1,
    subgroup = "tool",
    order = "c[automated-construction]-z[lbb-balancer-tool]",
    draw_label_for_cursor_render = false,
    skip_fog_of_war = false,
    -- drag: plan a balancer between the belt ends in the area
    select = {
      border_color = {r = 0.35, g = 0.85, b = 0.35},
      cursor_box_type = "copy",
      mode = {"any-entity", "same-force"},
      entity_type_filters = {"transport-belt", "underground-belt", "splitter"},
    },
    -- shift + drag: remove ghosts this tool placed
    alt_select = {
      border_color = {r = 0.9, g = 0.3, b = 0.3},
      cursor_box_type = "not-allowed",
      mode = {"any-entity", "same-force"},
      entity_type_filters = {"entity-ghost"},
    },
  },
  {
    type = "shortcut",
    name = "lbb-give-tool",
    action = "spawn-item",
    item_to_spawn = "lbb-balancer-tool",
    associated_control_input = "lbb-give-tool",
    icon = ICON,
    icon_size = 64,
    small_icon = ICON,
    small_icon_size = 64,
    order = "b[blueprints]-z[lbb]",
  },
  {
    type = "custom-input",
    name = "lbb-give-tool",
    key_sequence = "ALT + B",
    action = "spawn-item",
    item_to_spawn = "lbb-balancer-tool",
    consuming = "game-only",
    order = "a",
  },
  {
    type = "custom-input",
    name = "lbb-remove-last",
    key_sequence = "SHIFT + ALT + B",
    consuming = "game-only",
    order = "b",
  },
})
