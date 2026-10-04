-- Every design the planner may use: the hand-drawn ones first, then the
-- ones imported from a balancer blueprint book (tools/import_book.py).
local list = {}
for _, t in ipairs(require("scripts.templates")) do list[#list + 1] = t end
for _, t in ipairs(require("scripts.book_templates")) do list[#list + 1] = t end
return list
