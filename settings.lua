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
    -- planning runs over several ticks; this caps the work done in one tick
    type = "int-setting",
    name = "lbb-work-per-tick",
    setting_type = "runtime-global",
    default_value = 500,
    minimum_value = 100,
    maximum_value = 1000000,
    order = "c",
  },
  {
    -- planning that takes longer stops (placing the best layout found so far)
    type = "int-setting",
    name = "lbb-time-limit",
    setting_type = "runtime-global",
    default_value = 20,
    minimum_value = 1,
    maximum_value = 600,
    order = "d",
  },
  {
    type = "bool-setting",
    name = "lbb-verbose",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "b",
  },
})
