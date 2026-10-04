data:extend({
  {
    type = "string-setting",
    name = "lbb-tier",
    setting_type = "runtime-per-user",
    default_value = "fastest",
    allowed_values = {"fastest", "slowest"},
    order = "a",
  },
  {
    type = "bool-setting",
    name = "lbb-verbose",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "b",
  },
})
