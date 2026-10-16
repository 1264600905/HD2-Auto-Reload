-- Compile the entire packaged entry without executing or loading the addon.
assert(loadfile('build/auto_reload_entry.lua'))
print('1 complete packaged Lua syntax check passed')
