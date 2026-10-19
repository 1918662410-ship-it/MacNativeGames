# Generated game modules

The `.bin` files are extracted from your own copy of the game and are not
committed. Generate them with the Mac build's `tools/gen_embed.py`, then run
`xcodegen generate`. `embed.S` is a template; its `.incbin` paths are relative
to this directory.
