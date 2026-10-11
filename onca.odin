#+feature dynamic-literals
package onca

main :: proc() {

    pieces:    [dynamic; 15] Entity
    vertices:  [dynamic; 32] rl.Vector2

	init_game()
	defer close_game()

    assets := load_assets()
    defer unload_assets(assets)

    rl.PlayMusicStream(assets.bgm)

    for !rl.WindowShouldClose() {
		read_configs_noblocking()
	    // rl.UpdateMusicStream(assets.bgm)

	    adjacencies_and_captures: Adjacency
	    update(&pieces, &vertices, &adjacencies_and_captures, assets)

	    rl.BeginDrawing()
	    defer rl.EndDrawing()

	    if .Should_Render_Rules in flags {
		    render_rules(assets)
	    } else {
		    render_board(vertices[:], adjacencies_and_captures, assets)
		    render_pieces(pieces[:])
	    }
    }
}

init_game :: proc() {
    compute_adjacencies()

    nbio.acquire_thread_event_loop()

    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT});
    rl.InitWindow(cast(i32) SCREEN_WIDTH, cast(i32) SCREEN_HEIGHT, "Onca")

    rl.InitAudioDevice()
}

close_game :: proc() {
    nbio.release_thread_event_loop()
    rl.CloseWindow()
    rl.CloseAudioDevice()
}

load_assets :: proc() -> Assets {
	assets: Assets

	// SFX
    wave := rl.LoadWaveFromMemory(".wav", rawptr(raw_data(move_bytes)), cast(i32) len(move_bytes))
    assets.sfx_move = rl.LoadSoundFromWave(wave)
    rl.UnloadWave(wave)

    wave = rl.LoadWaveFromMemory(".wav", rawptr(raw_data(capture_bytes)), cast(i32) len(capture_bytes))
    assets.sfx_capture = rl.LoadSoundFromWave(wave)
    rl.UnloadWave(wave)

	// BGM
    assets.bgm = rl.LoadMusicStreamFromMemory(".wav", rawptr(raw_data(bgm_bytes)), cast(i32) len(bgm_bytes))

	// Font
    codepointCount: i32 = 0
    codepoints := rl.LoadCodepoints(
    	" !\"#$%&'()*+,-./0123456789:;<=>?ABCDEFGHIJKLMNOPQRSTUVWXYZÃ[\\]^_`abcdefghijklmnopqrstuvwxyzçéáíó{|}~",
    	&codepointCount
    )
    assets.font = rl.LoadFontFromMemory(".ttf", rawptr(raw_data(font_bytes)), cast(i32) len(font_bytes), 64, codepoints, codepointCount)
    rl.UnloadCodepoints(codepoints)

    return assets
}

unload_assets :: proc(assets: Assets) {
    rl.UnloadSound(assets.sfx_move)
    rl.UnloadSound(assets.sfx_capture)
    rl.UnloadMusicStream(assets.bgm)
    rl.UnloadFont(assets.font)
}

read_configs_noblocking :: proc() {
    if err := nbio.tick(timeout=0); err != nil {
	    log.errorf("nbio.tick: %v", err)
    }
    config_file_buffer: string

	parse_config_file :: proc(_: rawptr, buf: []byte, err: nbio.Read_Entire_File_Error) {
	    if err.value != nil {
		    log.errorf("str(%q): %v: %v", CONFIG_PATH, err.operation, err.value)
		    return
	    }

	    file := strings.trim(string(buf), " \n\t")

	    for line in strings.split_lines(file) {

		    config := strings.trim(line, " \n\t")
		    if config == "" do continue
		    pair   := strings.split(config, " ")
		    number,_ := strconv.parse_int(slice.last(pair))
		    configs[slice.first(pair)] = cast(u32) number
	    }
	}

    nbio.read_entire_file(CONFIG_PATH, &config_file_buffer, parse_config_file)
}

compute_adjacencies :: proc() {
	link :: proc(a, b: int) {
		adjacencies[a] += {b}
		adjacencies[b] += {a}
	}

	link_coords :: proc(a, b: [2]int) {
	    link(vert_from_coord(a.x, a.y), vert_from_coord(b.x, b.y))
	}

    // Square
   for v in 0 ..< 25 {
        if v < 20    do link(v, v+5)
        if v % 5 < 4 do link(v, v+1)
    }

	// Diagonals
    for v := 0; v <= 18; v += 2 {
	    j, i := coord_from_vert(v)
	    link_coords({i, j}, {i+1, j+1})
	    if v != 0 && v != 10 {
	    	link_coords({i, j}, {i-1, j+1})
    	}
    }

    // Triangle
    for v in 25 ..< 28 {
	    link(v, 22)
	    link(v, v+3)
    }
    for v in ([]int{26, 29}) {
	    link(v, v-1)
	    link(v, v+1)
    }
}

coord_from_vert :: proc(idx: int) -> (x, y: int){
    idx := clamp(idx, 0, 30)
    switch {
    case idx < 25: return idx/5, idx%5
    case idx < 28: return 6, idx - 24
    case:          return 5, idx - 27
    }
}

vert_from_coord :: proc(x, y: int) -> (idx: int) {
    x := clamp(x, 0, 6)
    y := clamp(y, 0, 4)
    switch x {
    case 5: return 27  + y   // middle row -> 28..30
    case 6: return 24  + y   // base row   -> 25..27
    case:   return x*5 + y
    }
}

update :: proc (
    pieces:  ^[dynamic; $N]Entity,
    vertices:  ^[dynamic; $O]rl.Vector2,
    adjacencies_and_captures: ^[31]bit_set[0..<31],
	assets: Assets) {

    update_scaling()
    update_vertices(vertices)

    border := cast(f32) configs["line_size"]
    width := UNIT * 0.6
    rules_rect = rl.Rectangle {
        SCREEN_WIDTH/2  - BOARD_WIDTH/2  + UNIT * 3 + (UNIT - width)/2,
        SCREEN_HEIGHT/2 - BOARD_HEIGHT/2 + UNIT * 6 - 40 - border,
        width,
        40,
    }

    width = UNIT * 0.65
    restart_rect = rl.Rectangle {
        SCREEN_WIDTH/2  - BOARD_WIDTH/2  + (UNIT - width)/2,
        SCREEN_HEIGHT/2 - BOARD_HEIGHT/2 + UNIT * 6 - 40 - border,
        width,
        40,
    }

    jaguar_size := cast(f32) configs["jaguar_size"]
    dog_size    := cast(f32) configs["dog_size"]
    vertex_size := cast(f32) configs["vertex_size"]

    mouse = rl.GetMousePosition()

    if rl.CheckCollisionPointRec(mouse, rules_rect) {
	    flags += {.Button_Hover}
	    if rl.IsMouseButtonPressed(.LEFT) {
	    	flags ~= {.Should_Render_Rules}
	    }
    } else {
		flags -= {.Button_Hover}
    }

    if rl.CheckCollisionPointRec(mouse, restart_rect) {
    	flags += {.Restart_Hover}
	    if rl.IsMouseButtonPressed(.LEFT) {
		    flags += {.Should_Restart}
	    }
    } else {
	    flags -= {.Restart_Hover}
    }

    if .Should_Restart in flags {
		    BOARD            = INITIAL_BOARD
		    score            = '0'
		    last_dog_move    = {}
		    last_jaguar_move = {}
		    jaguar_coord     = {2, 2}
		    dragged_piece    = {.n, {-1, -1}, {0, 0}}
		    flags            = {}
    }

    adjacencies_and_captures^ = compute_possible_captures()

    if .Last_Move_Was_Capture in flags {
	    jaguar := vert_from_coord(jaguar_coord.x, jaguar_coord.y)

	    if adjacencies_and_captures[jaguar] - adjacencies[jaguar] == {} {
	    	flags += {.Dogs_Turn}
	    	flags -= {.Last_Move_Was_Capture}
	    }
    }

    if check_if_dogs_won(adjacencies_and_captures[:]) {
	    flags += {.Dogs_Won}
	    return
    }

    if rl.IsMouseButtonDown(.LEFT) {
        for &e, idx in pieces {

            if dragged_piece.coord != {-1, -1} do continue
		    is_piece_clicked := false
            if e.kind == .J {
	            if  rl.CheckCollisionPointCircle(mouse, e.pos, jaguar_size) {
		            is_piece_clicked = true
	            }

            } else if e.kind == .D {
			    rect := rl.Rectangle{ e.pos.x, e.pos.y, dog_size, dog_size }
	            if  rl.CheckCollisionPointRec(mouse, rect) {
		            is_piece_clicked = true
			    }
            }

            if is_piece_clicked {
		        dragged_piece = {e.kind, e.coord, mouse}
            }
        }
    }

    if rl.IsMouseButtonUp(.LEFT) {
        if dragged_piece.coord != {-1, -1} {
	        vert := vert_from_coord(dragged_piece.coord.x, dragged_piece.coord.y)
	        possible_moves := adjacencies_and_captures[vert]
	        if .Last_Move_Was_Capture in flags {
		        possible_moves -= adjacencies[vert]
	        }
		    for idx in possible_moves {
			    v := vertices[idx]
			    i, j := coord_from_vert(idx)
			    if BOARD[i][j] != .n do continue
			    got_new_coord := false
			    if dragged_piece.kind == .J && .Dogs_Turn not_in flags {
				    if rl.CheckCollisionCircles(mouse, jaguar_size, v, vertex_size * 3) {
					    got_new_coord = true
					    if idx in (adjacencies_and_captures[vert] - adjacencies[vert]) {
						    captured := index_captured(vert, idx)
						    x, y := coord_from_vert(captured)
						    BOARD[x][y] = .n
						    score += 1
						    flags += {.Last_Move_Was_Capture}
					    }
					    last_jaguar_move[0] = vert
					    last_jaguar_move[1] = idx
					    if idx in adjacencies[vert] {
						    flags += {.Dogs_Turn}
					    }
				    }
			    }
			    if dragged_piece.kind == .D  && .Dogs_Turn in flags {
				    x := mouse.x - dog_size / 2
				    y := mouse.y - dog_size / 2
				    rect := rl.Rectangle{ x, y, dog_size, dog_size }
				    if rl.CheckCollisionCircleRec(v, vertex_size * 3, rect) {
					    got_new_coord = true
					    flags -= {.Dogs_Turn}
					    last_dog_move[0] = vert
					    last_dog_move[1] = idx
				    }
			    }

			    x, y := coord_from_vert(idx)
			    if got_new_coord && BOARD[x][y] == .n &&
			       dragged_piece.coord != ([2]int{x,y}) {

				    BOARD[x][y] = dragged_piece.kind
				    if BOARD[x][y] == .J do jaguar_coord = {x,y}
				    sfx := assets.sfx_capture if .Last_Move_Was_Capture in flags else assets.sfx_move
				    rl.PlaySound(sfx)

				    x, y = dragged_piece.coord.x, dragged_piece.coord.y
				    BOARD[x][y] = .n

				    break
			    }
		    }
	    }
	    dragged_piece = {.n, {-1, -1}, {0,0}}
    }

    update_pieces(pieces, vertices[:])
}

update_scaling :: proc() {
    SCREEN_WIDTH  = cast(f32) rl.GetScreenWidth()
    SCREEN_HEIGHT = cast(f32) rl.GetScreenHeight()
    SCALE         = cast(f32) configs["scale"] / 100
    UNIT          = min(SCREEN_WIDTH * SCALE / 4, SCREEN_HEIGHT * SCALE / 6)
    BOARD_WIDTH   = UNIT * 4
    BOARD_HEIGHT  = UNIT * 6
}

update_pieces :: proc(pieces: ^[dynamic; $M] Entity, vertices: []rl.Vector2) {

    clear(pieces)

    for kinds, x in BOARD {
	    for _, y in kinds {

		    e := BOARD[x][y]
		    if e == .n || e == .i do continue

		    pos: rl.Vector2
		    idx := vert_from_coord(x,y)
		    pos = vertices[idx]
		    if e == .D {
			    pos -= cast(f32) configs["dog_size"]/2
		    }

		    append(pieces, Entity{e, {x, y}, pos})
	    }
    }
}

index_over_piece :: proc(jag, dog: int) -> int {
    idx := dog - (jag - dog)
    if dog == 22 {
	    switch jag {
	    case 16 ..= 18, 25 ..= 27: idx -= 1
	    }
    } else if dog == 26 && (jag == 22 || jag == 29) {
	    idx -= 1
    } else if dog == 27 && (jag == 22 || jag == 30) {
	    idx -= 2
    }
    return idx
}

index_captured :: proc(src, dst: int) -> int {
    captured := min(src, dst) + abs((dst - src) / 2)
    switch src + dst {
    case 43, 51, 52:
	    if src != 25 || dst != 25 {
		    captured += 1
	    }
    }
    return captured
}

compute_possible_captures :: proc() -> [31]bit_set[0..<31] {
    adjacencies_and_captures := adjacencies
    jaguar := vert_from_coord(jaguar_coord.x, jaguar_coord.y)

    for i in adjacencies[jaguar] {
	    x, y := coord_from_vert(i)
	    if BOARD[x][y] == .D {
		    new_move := index_over_piece(jaguar, i)
		    x, y = coord_from_vert(new_move)
		    if new_move in adjacencies[i] && BOARD[x][y] == .n {
			    adjacencies_and_captures[jaguar] += {index_over_piece(jaguar, i)}
		    }
	    }
    }
    return adjacencies_and_captures
}

update_vertices :: proc (vertices: ^[dynamic; $N] rl.Vector2) {

    clear(vertices)
    origin := rl.Vector2{ SCREEN_WIDTH/2  - BOARD_WIDTH/2,
				          SCREEN_HEIGHT/2 - BOARD_HEIGHT/2 }

    center := origin

    for i in 1 ..< 6 {
	    for j in 1 ..< 6 {
		    append(vertices, center)
		    center += rl.Vector2{UNIT, 0}
	    }
	    center = rl.Vector2{origin.x, origin.y + cast(f32)i * UNIT}
    }

    center = rl.Vector2{origin.x + 1.5 * UNIT, origin.y + 5 * UNIT}
    for _ in 0 ..< 3 {
	    append(vertices, center)
	    center += rl.Vector2{UNIT/2, 0}
    }

    center = rl.Vector2{origin.x + UNIT, origin.y + 6 * UNIT}
    for _ in 0 ..< 3 {
	    append(vertices, center)
	    center += rl.Vector2{UNIT, 0}
    }
}

check_if_dogs_won :: proc(adjacencies_and_captures: []bit_set[0..<31]) -> bool {

    if .Dogs_Turn in flags {
	    return false
    }

    jaguar := vert_from_coord(jaguar_coord.x, jaguar_coord.y)

    if .Dogs_Turn not_in flags {
	    for vert in adjacencies_and_captures[jaguar] {
		    x, y := coord_from_vert(vert)
		    if BOARD[x][y] == .n {
			    return false
		    }
	    }
    }

    return true
}

render_board :: proc(vertices: []rl.Vector2, adjacencies_and_captures: [31]bit_set[0..<31], assets: Assets) {

    // Background
    rl.ClearBackground(rl.GetColor(configs["bg_color"]))

    // Board Square
    rect := rl.Rectangle {
    SCREEN_WIDTH/2  - BOARD_WIDTH/2,
        SCREEN_HEIGHT/2 - BOARD_HEIGHT/2,
        BOARD_WIDTH,
        BOARD_WIDTH,
    }

    rl.DrawRectangleRec(rect, rl.GetColor(configs["fg_color"]))

    // Board Triangle
    v1 := rl.Vector2{SCREEN_WIDTH/2, rect.y + UNIT * 4}
    v2 := rl.Vector2{v1.x - UNIT, v1.y + 2*UNIT}
    v3 := rl.Vector2{v1.x + UNIT, v1.y + 2*UNIT}

    rl.DrawTriangle(v1, v2, v3, rl.GetColor(configs["fg_color"]))

    // Lines
    start := rl.Vector2{rect.x, rect.y}
    end   := start + rl.Vector2{UNIT * 4, 0}

    for i in 0 ..< 4 {
	    start += rl.Vector2{0, UNIT}
	    end   += rl.Vector2{0, UNIT}
	    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))
    }
    start = rl.Vector2{rect.x + UNIT * 1.5, rect.y + UNIT * 5}
    end   = start + rl.Vector2{UNIT, 0}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start = rl.Vector2{rect.x + UNIT * 1, rect.y}
    end   = start + rl.Vector2{0, UNIT * 4}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start += rl.Vector2{UNIT * 1, 0}
    end   += rl.Vector2{UNIT * 1, UNIT * 2}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start += rl.Vector2{UNIT * 1, 0}
    end   += rl.Vector2{UNIT * 1, -(UNIT * 2)}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start = rl.Vector2{rect.x, rect.y}
    end   = start + rl.Vector2{UNIT * 4, UNIT * 4}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start = rl.Vector2{rect.x + UNIT * 4, rect.y}
    end   = rl.Vector2{rect.x, rect.y + UNIT * 4}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start = rl.Vector2{rect.x + UNIT * 2, rect.y}
    end   = rl.Vector2{rect.x, rect.y + UNIT * 2}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start = rl.Vector2{rect.x + UNIT * 2, rect.y}
    end   = rl.Vector2{rect.x + UNIT * 4, rect.y + UNIT * 2}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start = rl.Vector2{rect.x + UNIT * 2, rect.y + UNIT * 4}
    end   = rl.Vector2{rect.x, rect.y + UNIT * 2}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    start = rl.Vector2{rect.x + UNIT * 2, rect.y + UNIT * 4}
    end   = rl.Vector2{rect.x + UNIT * 4, rect.y + UNIT * 2}
    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["bg_color"]))

    // Score
    w := rect.x
    h := rect.y + 4.2 * UNIT
    score_text := cstring(raw_data([]u8{score, 0}))
    rl.DrawTextEx(assets.font, score_text, rl.Vector2{w, h}, 50, 0, rl.LIGHTGRAY);

    // Render Last Move
    render_last_move(vertices[:])

    for v, idx in vertices {
	    color := rl.WHITE
	    last_move := last_jaguar_move if .Dogs_Turn in flags || .Last_Move_Was_Capture in flags else
			         last_dog_move

	    if idx == last_move[0] {
		    color = rl.GetColor(configs["last_move_color"])
	    }
	    if dragged_piece.coord != {-1, -1} {
		    dragged_idx := vert_from_coord(dragged_piece.coord.x, dragged_piece.coord.y)
		    possible_moves := adjacencies_and_captures[dragged_idx]
		    if .Last_Move_Was_Capture in flags {
			    possible_moves -= adjacencies[dragged_idx]
		    }
		    if idx in possible_moves {
			    color = rl.GetColor(configs["highlight_color"])
		    }
	    }
	    rl.DrawCircleV(v, cast(f32) configs["vertex_size"], color)
	    render_highlight_around_circle(
	        v,
	        cast(f32) configs["vertex_size"],
	        cast(f32) configs["line_size"],
	        rl.GetColor(configs["bg_color"])
		)
    }

    render_button("Regras",    cast(f32) configs["line_size"], rules_rect,   .Button_Hover  in flags, assets)
    render_button("Reiniciar", cast(f32) configs["line_size"], restart_rect, .Restart_Hover in flags, assets)

    if score == '5' {
	    render_last_move(vertices[:])
	    render_victory(.J, assets)
	    return
    }
    if .Dogs_Won in flags {
	    render_victory(.D, assets)
	    return
    }
}

render_button :: proc(label: cstring, thickness: f32, rect: rl.Rectangle, hover: bool, assets: Assets) {
    color1 := rl.GetColor(configs["button_fg_color"])
    color2 := rl.GetColor(configs["button_bg_color"])
    if hover do color1, color2 = color2, color1
    rl.DrawRectangleRec(rect, color1)
    render_highlight_around_rect(rect, thickness, rl.GetColor(configs["fg_color"]))

    font_size: f32 : 30
    text_size := cast(f32) rl.MeasureText(label, cast(i32)font_size)
    w := rect.x + rect.width  / 2 - text_size * 0.34
    h := rect.y + rect.height / 2 - font_size / 2
    rl.DrawTextEx(assets.font, label, rl.Vector2{w, h}, font_size, 0, color2);
}

render_highlight_around_rect :: proc(rect: rl.Rectangle, thickness: f32, color: rl.Color) {
    rect := rect
    rect.x -= thickness
    rect.y -= thickness
    rect.width += thickness * 2
    rect.height += thickness * 2
    rl.DrawRectangleLinesEx(rect, thickness, color)
}

render_highlight_around_circle :: proc (center: rl.Vector2, size: f32, thickness: f32, color: rl.Color) {
    rl.DrawRing(center, size, size + thickness, 0, 360, 0, color)
}

render_pieces :: proc(pieces: []Entity) {
    jaguar_size := cast(f32) configs["jaguar_size"]
    dog_size    := cast(f32) configs["dog_size"]

    LERP :: 0.8

    for e in pieces {
	    if e.kind == .D {
		    rect := rl.Rectangle{ e.pos.x, e.pos.y, dog_size, dog_size }
		    color := rl.GetColor(configs["dog_color"])
		    if dragged_piece.coord == e.coord {
			    color = rl.ColorLerp(color, rl.Color{0, 0, 0, 255}, LERP)
		    }
		    rl.DrawRectangleRec(rect, color)
		    render_highlight_around_rect(rect, cast(f32) configs["line_size"], rl.Color{0,0,0,255})

	    } else if e.kind == .J {
		    color := rl.GetColor(configs["jaguar_color"])
		    if dragged_piece.coord == e.coord {
			    color = rl.ColorLerp(color, rl.Color{0, 0, 0, 255}, LERP)
		    }
		    rl.DrawCircleV(e.pos, jaguar_size, color)
		    render_highlight_around_circle(
		        e.pos,
		        jaguar_size,
		        cast(f32) configs["line_size"],
		        rl.Color{0,0,0,255}
			)
	    }
    }

    if dragged_piece.kind == .D {
	    x := mouse.x - dog_size / 2
	    y := mouse.y - dog_size / 2
	    rect := rl.Rectangle{ x, y, dog_size, dog_size }
	    rl.DrawRectangleRec(rect, rl.GetColor(configs["dog_color"]))
	    render_highlight_around_rect(rect, cast(f32) configs["border_size"], rl.GetColor(configs["highlight_color"]))

    } else if dragged_piece.kind == .J {
	    rl.DrawCircleV(mouse, jaguar_size, rl.GetColor(configs["jaguar_color"]))
	    render_highlight_around_circle(
		    mouse,
		    cast(f32) configs["jaguar_size"],
		    cast(f32) configs["border_size"],
			rl.GetColor(configs["highlight_color"])
		)
    }
}

render_last_move :: proc(vertices: []rl.Vector2) {
    jaguar_size := cast(f32) configs["jaguar_size"]
    dog_size    := cast(f32) configs["dog_size"]
    vertex_size := cast(f32) configs["vertex_size"]

    last_move := last_jaguar_move if .Dogs_Turn in flags || .Last_Move_Was_Capture in flags else
			     last_dog_move

	is_jaguar_move := .Dogs_Turn in flags || .Last_Move_Was_Capture in flags
	was_capture    := is_jaguar_move && !(last_move[1] in adjacencies[last_move[0]])

    border := cast(f32) configs["border_size"]

    start := vertices[last_move[0]]
    end   := vertices[last_move[1]]

    cap_idx := index_captured(last_move[0], last_move[1])
    if was_capture && cap_idx == 22 {
	    cap := vertices[cap_idx]
	    rl.DrawLineEx(start, cap, 4,
	    rl.GetColor(configs["last_move_color"]))
	    rl.DrawLineEx(cap, end, 4, rl.GetColor(configs["last_move_color"]))
    } else {
	    rl.DrawLineEx(start, end, 4, rl.GetColor(configs["last_move_color"]))
    }

    rl.DrawCircleV(start, vertex_size, rl.GetColor(configs["last_move_color"]))
    if .Dogs_Turn in flags && .Last_Move_Was_Capture not_in flags {
	    rl.DrawRing(end, jaguar_size, jaguar_size + border * 1.2,
	    0, 360, 0, rl.GetColor(configs["last_move_color"]))
    } else {
	    if last_dog_move != {0, 0} {
		    rect := rl.Rectangle {
			    end.x - dog_size/2 - border,
			    end.y - dog_size/2 - border,
			    dog_size + border* 2, dog_size + border* 2,
		    }
		    rl.DrawRectangleLinesEx(rect, border * 1.3, rl.GetColor(configs["last_move_color"]))
	    }
    }
}

render_rules :: proc(assets: Assets) {
    rl.ClearBackground(rl.GetColor(configs["bg_color"]))

    rules_text := []cstring {
    "2 jogadores jogam em turnos: um com",
    "a Onça, o outro com os Cachorros.",
    "",
    "",
    "Em seu turno, mova uma peça para um",
    "vértice vizinho pelas linhas do",
    "tabuleiro: vertical, horizontal ou",
    "diagonal.",
    "",
    "",
    "A Onça também pode saltar sobre um",
    "cachorro, capturando-o, se a casa",
    "logo atrás dele estiver vazia. Após",
    "capturar, deve continuar saltando",
    "enquanto houver capturas possíveis.",
    "",
    "",
    "Onça vence ao capturar 5 Cachorros.",
    "Cachorros vencem se encurralarem a",
    "Onça (sem movimentos possíveis).",
    }

    font_size: f32 = 45
    w := SCREEN_WIDTH/2  - BOARD_WIDTH/2
    h := SCREEN_HEIGHT/2 - BOARD_HEIGHT/2 - font_size

    for line in rules_text {
	    h += font_size * 0.75
	    rl.DrawTextEx(assets.font, line, rl.Vector2{w, h}, font_size, 1, rl.RAYWHITE)
    }

    render_button("Voltar", cast(f32) configs["line_size"], rules_rect, .Button_Hover in flags, assets)
}


render_victory :: proc (kind: Entity_Kind, assets: Assets) {
    mesg1, mesg2: cstring
    color: rl.Color
    switch kind {
    case .J: mesg1 = "A ONCA"
             mesg2 = "GANHOU"
     color = rl.GetColor(configs["jaguar_color"])
    case .D: mesg1 = "OS CÃES"
             mesg2 = "GANHARAM"
     color = rl.GetColor(configs["dog_color"])

    case .n, .i: return
    }

    // Board Square
    rect := rl.Rectangle {
        SCREEN_WIDTH/2  - BOARD_WIDTH/2,
        SCREEN_HEIGHT/2 - BOARD_HEIGHT/2,
        BOARD_WIDTH,
        BOARD_WIDTH,
    }
    w := rect.x
    h := rect.y + UNIT * 4.5
    rl.DrawTextEx(assets.font, mesg1, rl.Vector2{w, h},      36, 0, color);
    rl.DrawTextEx(assets.font, mesg2, rl.Vector2{w, h + 38}, 36, 0, color);
}

// Constants
CONFIG_PATH :: "onca.cfg"

configs := map[string]u32 {
    "scale"            = 90,
    "screen_width"     = 1200,
    "screen_height"    = 800,

    "border_size"      = 8,
    "line_size"        = 4,
    "vertex_size"      = 10,
    "dog_size"         = 32,
    "jaguar_size"      = 25,

    "bg_color"         = 0x160802ff,
    "fg_color"         = 0xd8a71eff,
    "button_bg_color"  = 0x160802ff,
    "button_fg_color"  = 0xd8a71eff,
    "dog_color"        = 0x473d2fff,
    "jaguar_color"     = 0xf2cf46ff,
    "highlight_color"  = 0x0fa0b0ff,
    "last_move_color"  = 0x10aa10ff,
}

SCALE:         f32 = cast(f32) configs["scale"] / 100
SCREEN_WIDTH:  f32 = cast(f32) configs["screen_width"]
SCREEN_HEIGHT: f32 = cast(f32) configs["screen_height"]
UNIT:          f32 = min(SCREEN_WIDTH * SCALE / 4, SCREEN_HEIGHT * SCALE / 6)
BOARD_WIDTH:   f32 = UNIT * 4
BOARD_HEIGHT:  f32 = UNIT * 6

mouse:        rl.Vector2
rules_rect:   rl.Rectangle
restart_rect: rl.Rectangle

State_Flags :: enum {
	Button_Hover,
	Should_Render_Rules,
	Restart_Hover,
	Should_Restart,
	Dogs_Turn,
	Last_Move_Was_Capture,
	Dogs_Won,
}
flags: bit_set[State_Flags]

Entity_Kind :: enum {n, i, D, J}
dragged_piece: Entity = {.n, {-1, -1}, {0, 0}}
score: u8 = '0'

jaguar_coord     := [2]int{2, 2}
last_jaguar_move := [2]int{0, 12}
last_dog_move    := [2]int{0,  0}

INITIAL_BOARD := [7][5] Entity_Kind {
    {.D, .D, .D, .D, .D},
    {.D, .D, .D, .D, .D},
    {.D, .D, .J, .D, .D},
    {.n, .n, .n, .n, .n},
    {.n, .n, .n, .n, .n},
    {.i, .n, .n, .n, .i},
    {.i, .n, .n, .n, .i},
}

BOARD := INITIAL_BOARD

Entity :: struct {
    kind:  Entity_Kind,
    coord: [2]int,
    pos:   rl.Vector2,
}

Adjacency :: [31]bit_set[0..<31]
adjacencies: Adjacency

Assets :: struct {
	sfx_move:    rl.Sound,
	sfx_capture: rl.Sound,
	bgm:         rl.Music,
	font:        rl.Font,
}

// assets: Assets

move_bytes    :: #load("move.wav")
capture_bytes :: #load("capture.wav")
bgm_bytes     :: #load("bgm.wav")
font_bytes    :: #load("Black Animal.ttf")

import "core:fmt"
import "core:nbio"
import "core:log"
import "core:strings"
import "core:slice"
import "core:strconv"
import rl "vendor:raylib"

/*
@TODO:
[ ] Better Colors
[ ] Implement images for the rules

@BUGS:
[ ] after a capture on the triangle the last_move around highlight use a rect instead of a circle
[ ] changing configs after gameover do not update rendering

@REFACTOR:
[ ] collapse data into game_state, input and render structs
[ ] refactor highlight last_move and highlight on hover code
[ ] refactor button logic

[ ] Implement Skip button after captures ???
[ ] animation for piece capture @VISUAL
[ ] Change highlight color for piece that could be captured on a possible move
[ ] recompute rects, triangles, and lines for rendering the board only on resize
[ ] implement networking
[ ] implement computer AI

*/

