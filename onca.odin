#+feature dynamic-literals
package onca

main :: proc() {

    vertices:  [dynamic; 32] rl.Vector2

    init_game()
    defer close_game()

    assets := load_assets()
    defer unload_assets(assets)

    rl.PlayMusicStream(assets.bgm)

    for !rl.WindowShouldClose() {
        read_configs_noblocking()
        rl.UpdateMusicStream(assets.bgm)

        adjacencies_and_captures: Adjacency
        update(&vertices, &adjacencies_and_captures, assets)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        if .Should_Render_Rules in flags {
            render_rules(assets)
        } else {
            render_board(vertices[:], adjacencies_and_captures, assets)
            render_pieces(vertices[:])
        }
    }
}

init_game :: proc() {
    build_topology()

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
    load_sound_from_memory :: proc(sfx: ^rl.Sound, bytes: []u8) {
        wave := rl.LoadWaveFromMemory(".wav", rawptr(raw_data(bytes)), cast(i32) len(bytes))
        sfx^  = rl.LoadSoundFromWave(wave)
        rl.UnloadWave(wave)
    }
    load_sound_from_memory(&assets.sfx_move,    move_bytes)
    load_sound_from_memory(&assets.sfx_capture, capture_bytes)

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
            pair     := strings.split(config, " ")
            key := slice.first(pair)
            keys :: []string {
                "scale",
                "screen_width",
                "screen_height",
                "border_size",
                "line_size",
                "vertex_size",
                "dog_size",
                "jaguar_size",
                "bg_color",
                "fg_color",
                "button_bg_color",
                "button_fg_color",
                "dog_color",
                "jaguar_color",
                "highlight_color",
                "last_move_color",
            }
            valid := false
            color := true if strings.contains(key, "color") else false
            for k in keys {
                if k == key {
                    valid = true
                }
            }
            if !valid {
                log.errorf("config invalid: %v", key)
                return
            }
            if color {
                number,_ := strconv.parse_int(slice.last(pair))
                configs[key] = cast(u32) number
            } else {
                number,_ := strconv.parse_f32(slice.last(pair))
                configs[key] = number
            }
        }
    }

    nbio.read_entire_file(CONFIG_PATH, &config_file_buffer, parse_config_file)
}

update :: proc (
    vertices:  ^[dynamic; $O]rl.Vector2,
    adjacencies_and_captures: ^Adjacency,
    assets: Assets) {

    update_scaling()
    update_vertices(vertices)

    border := configs["line_size"].(f32)
    width  := UNIT * 0.6
    height := UNIT * 0.4
    rules_rect = rl.Rectangle {
        SCREEN_WIDTH/2  - BOARD_WIDTH/2  + UNIT * 3 + (UNIT - width)  * 0.5,
        SCREEN_HEIGHT/2 - BOARD_HEIGHT/2 + UNIT * 6 - (UNIT - height) * 0.71,
        width,
        height,
    }

    width = UNIT * 0.65
    restart_rect = rules_rect
    restart_rect.x =  SCREEN_WIDTH/2 - BOARD_WIDTH/2 + (UNIT - width)/2

    jaguar_size,_ := configs["jaguar_size"].(f32)
    dog_size,_    := configs["dog_size"].(f32)
    vertex_size,_ := configs["vertex_size"].(f32)
    vertex_size *= UNIT
    jaguar_size *= UNIT
    dog_size *= UNIT

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
        jaguar_idx       = 12
        drag_from        = -1
        last_jaguar_move = {}
        last_dog_move    = {}
        flags            = {}
        score            = '0'
    }

    adjacencies_and_captures^ = compute_possible_captures()

    if .Last_Move_Was_Capture in flags {
        if adjacencies_and_captures[jaguar_idx] - adjacencies[jaguar_idx] == {} {
            flags += {.Dogs_Turn}
            flags -= {.Last_Move_Was_Capture}
        }
    }

    if check_if_dogs_won(adjacencies_and_captures^) {
        flags += {.Dogs_Won}
    }
    game_over := score == '5' || .Dogs_Won in flags

    if drag_from < 0 && rl.IsMouseButtonDown(.LEFT) {
        for piece, idx in BOARD {
            hit := false
            collision_multiplier :: 2
            switch piece {
            case .Jaguar: hit = rl.CheckCollisionPointCircle(mouse, vertices[idx], jaguar_size * collision_multiplier)
            case .Dog:    hit = rl.CheckCollisionPointRec(mouse, center_rect(vertices[idx], dog_size * collision_multiplier * 1.5))
            case .None:
            }
            if hit { drag_from = idx; break }
        }
    }

    if rl.IsMouseButtonUp(.LEFT) {
        if !game_over && drag_from >= 0 {
            piece := BOARD[drag_from]
            moves := adjacencies_and_captures[drag_from]
            if .Last_Move_Was_Capture in flags do moves -= adjacencies[drag_from]

            for to in moves {
                if BOARD[to] != .None do continue
                moved := false
                collision_size := vertex_size * 4
                switch {
                case piece == .Jaguar && .Dogs_Turn not_in flags:
                    if rl.CheckCollisionCircles(mouse, jaguar_size, vertices[to], collision_size) {
                        moved = true
                        if to in adjacencies[drag_from] {
                            flags += {.Dogs_Turn}
                        } else {                                   // a jump
                            over,_ := find_jump(drag_from, to)
                            BOARD[over] = .None
                            score += 1
                            flags += {.Last_Move_Was_Capture}
                        }
                        last_jaguar_move = {drag_from, to}
                    }
                case piece == .Dog && .Dogs_Turn in flags:
                    if rl.CheckCollisionCircleRec(vertices[to], collision_size, center_rect(mouse, dog_size)) {
                        moved = true
                        flags -= {.Dogs_Turn}
                        last_dog_move = {drag_from, to}
                    }
                }
                if moved {
                    BOARD[drag_from], BOARD[to] = .None, piece
                    if piece == .Jaguar do jaguar_idx = to
                    rl.PlaySound(assets.sfx_capture if .Last_Move_Was_Capture in flags else assets.sfx_move)
                    break
                }
            }
        }
        drag_from = -1
    }
}

center_rect :: proc(pos: rl.Vector2, size: f32) -> rl.Rectangle {
    return {pos.x - size/2, pos.y - size/2, size, size}
}

update_scaling :: proc() {
    SCREEN_WIDTH  = cast(f32) rl.GetScreenWidth()
    SCREEN_HEIGHT = cast(f32) rl.GetScreenHeight()
    scale, ok     := configs["scale"].(f32)
    SCALE         = scale * 0.01
    UNIT          = min(SCREEN_WIDTH * SCALE / 4, SCREEN_HEIGHT * SCALE / 6)
    BOARD_WIDTH   = UNIT * 4
    BOARD_HEIGHT  = UNIT * 6
}

compute_possible_captures :: proc() -> Adjacency {
    adjacencies_and_captures := adjacencies

    for j in JUMPS {
        if j.from        == jaguar_idx &&
           BOARD[j.over] == .Dog       &&
           BOARD[j.to]   == .None {
                adjacencies_and_captures[jaguar_idx] += {j.to}
        }
    }
    return adjacencies_and_captures
}

update_vertices :: proc (vertices: ^[dynamic; $N] rl.Vector2) {

    clear(vertices)
    origin := rl.Vector2{ SCREEN_WIDTH/2  - BOARD_WIDTH/2,
                          SCREEN_HEIGHT/2 - BOARD_HEIGHT/2 }

    center := origin

    // Square
    for i in 1 ..< 6 {
        for j in 1 ..< 6 {
            append(vertices, center)
            center += rl.Vector2{UNIT, 0}
        }
        center = rl.Vector2{origin.x, origin.y + cast(f32)i * UNIT}
    }

    // Triangle
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

check_if_dogs_won :: proc(adjacencies_and_captures: Adjacency) -> bool {

    if .Dogs_Turn in flags do return false

    for vert in adjacencies_and_captures[jaguar_idx] {
        if BOARD[vert] == .None do return false
    }
    return true
}

render_board :: proc(vertices: []rl.Vector2, adjacencies_and_captures: Adjacency, assets: Assets) {
    vertex_size,_     := configs["vertex_size"].(f32)
    line_size,_       := configs["line_size"].(f32)
    bg_color,_        := configs["bg_color"].(u32)
    fg_color,_        := configs["fg_color"].(u32)
    last_move_color,_ := configs["last_move_color"].(u32)
    highlight_color,_ := configs["highlight_color"].(u32)
    vertex_size *= UNIT
    // line_size *= UNIT

    // Background
    rl.ClearBackground(rl.GetColor(bg_color))

    // Board Square
    rect := rl.Rectangle {
        SCREEN_WIDTH/2  - BOARD_WIDTH/2,
        SCREEN_HEIGHT/2 - BOARD_HEIGHT/2,
        BOARD_WIDTH,
        BOARD_WIDTH,
    }
    rl.DrawRectangleRec(rect, rl.GetColor(configs["fg_color"].(u32)))

    // Board Triangle
    v1 := rl.Vector2{SCREEN_WIDTH/2, rect.y + UNIT * 4}
    v2 := rl.Vector2{v1.x - UNIT, v1.y + 2*UNIT}
    v3 := rl.Vector2{v1.x + UNIT, v1.y + 2*UNIT}
    rl.DrawTriangle(v1, v2, v3, rl.GetColor(fg_color))

    // Lines
    for i in 1 ..= 3 {
        rl.DrawLineEx(vertices[i],   vertices[20+i],  4, rl.GetColor(bg_color))
        rl.DrawLineEx(vertices[5*i], vertices[5*i+4], 4, rl.GetColor(bg_color))
    }

    // Diagonal Lines
    for v in ([?]int{6, 8, 16, 18}) {
        pos := vertices[v]
        start := pos - rl.Vector2{UNIT, UNIT}
        end   := pos + rl.Vector2{UNIT, UNIT}
        rl.DrawLineEx(start, end, 4, rl.GetColor(bg_color))

        start += rl.Vector2{2*UNIT,0}
        end   -= rl.Vector2{2*UNIT,0}
        rl.DrawLineEx(start, end, 4, rl.GetColor(bg_color))
    }

    // Triangle Lines
    rl.DrawLineEx(vertices[22], vertices[29], 4, rl.GetColor(bg_color))
    rl.DrawLineEx(vertices[25], vertices[27], 4, rl.GetColor(bg_color))

    // Score
    w := rect.x
    h := rect.y + 4.2 * UNIT
    font_size := UNIT * 0.45
    score_text := cstring(raw_data([]u8{score, 0}))
    rl.DrawTextEx(assets.font, score_text, rl.Vector2{w, h}, font_size, 0, rl.LIGHTGRAY);

    // Render Last Move
    render_last_move(vertices[:])

    highlight_from := drag_from
    if .Last_Move_Was_Capture in flags && score != '5' {
        highlight_from = jaguar_idx
    }

    // Render vertices
    for v, idx in vertices {
        color := rl.WHITE
        last_move := last_jaguar_move if .Dogs_Turn in flags || .Last_Move_Was_Capture in flags else
                     last_dog_move

        if idx == last_move[0] {
            color = rl.GetColor(last_move_color)
        }
        if highlight_from >= 0 {
            possible_moves := adjacencies_and_captures[highlight_from]
            if .Last_Move_Was_Capture in flags {
                possible_moves -= adjacencies[highlight_from]
            }
            if idx in possible_moves {
                color = rl.GetColor(highlight_color)
            }
        }

        rl.DrawCircleV(v, vertex_size, color)
        render_highlight_around_circle(
            v,
            vertex_size,
            line_size,
            rl.GetColor(bg_color)
        )
    }

    render_button("Regras",    line_size, rules_rect,   .Button_Hover  in flags, assets)
    render_button("Reiniciar", line_size, restart_rect, .Restart_Hover in flags, assets)

    if score == '5' {
        render_victory(.Jaguar, assets)
        return
    }
    if .Dogs_Won in flags {
        render_victory(.Dog, assets)
        return
    }
}

render_button :: proc(label: cstring, thickness: f32, rect: rl.Rectangle, hover: bool, assets: Assets) {
    color1 := rl.GetColor(configs["button_fg_color"].(u32))
    color2 := rl.GetColor(configs["button_bg_color"].(u32))
    if hover do color1, color2 = color2, color1
    rl.DrawRectangleRec(rect, color1)
    render_highlight_around_rect(rect, thickness, rl.GetColor(configs["fg_color"].(u32)))

    font_size: f32 = UNIT * 0.19
    text_size := rl.MeasureTextEx(assets.font, label, font_size, 0)
    w := rect.x + rect.width  * 0.5 - text_size.x * 0.5
    h := rect.y + rect.height * 0.5 - font_size   * 0.5
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

render_pieces :: proc(vertices: []rl.Vector2) {
    jaguar_size,_     := configs["jaguar_size"].(f32)
    dog_size,_        := configs["dog_size"].(f32)
    line_size,_       := configs["line_size"].(f32)
    jaguar_color,_    := configs["jaguar_color"].(u32)
    dog_color,_       := configs["dog_color"].(u32)
    highlight_color,_ := configs["highlight_color"].(u32)
    jaguar_size *= UNIT
    dog_size *= UNIT

    LERP :: 0.8

    for piece, idx in BOARD {
        if piece == .None do continue
        if piece == .Dog {
            rect  := center_rect(vertices[idx], dog_size)
            color := rl.GetColor(dog_color)
            if idx == drag_from {
                color = rl.ColorLerp(color, rl.Color{0, 0, 0, 255}, LERP)
            }
            rl.DrawRectangleRec(rect, color)
            render_highlight_around_rect(rect, line_size, rl.Color{0,0,0,255})

        } else if piece == .Jaguar {
            color := rl.GetColor(jaguar_color)
            if idx == drag_from {
                color = rl.ColorLerp(color, rl.Color{0, 0, 0, 255}, LERP)
            }
            rl.DrawCircleV(vertices[idx], jaguar_size, color)
            render_highlight_around_circle(
                vertices[idx],
                jaguar_size,
                line_size,
                rl.Color{0,0,0,255}
            )
        }
    }

    if drag_from < 0 do return

    if BOARD[drag_from] == .Dog {
        rect := center_rect(mouse, dog_size)
        rl.DrawRectangleRec(rect, rl.GetColor(dog_color))
        render_highlight_around_rect(rect, line_size, rl.GetColor(highlight_color))

    } else if BOARD[drag_from] == .Jaguar {
        rl.DrawCircleV(mouse, jaguar_size, rl.GetColor(jaguar_color))
        render_highlight_around_circle(
            mouse,
            jaguar_size,
            line_size,
            rl.GetColor(highlight_color)
        )
    }
}

render_last_move :: proc(vertices: []rl.Vector2) {
    jaguar_size,_ := configs["jaguar_size"].(f32)
    dog_size,_    := configs["dog_size"].(f32)
    vertex_size,_ := configs["vertex_size"].(f32)
    vertex_size   *= UNIT
    jaguar_size    *= UNIT
    dog_size      *= UNIT

    last_move := last_jaguar_move if .Dogs_Turn in flags || .Last_Move_Was_Capture in flags else
                 last_dog_move

    is_jaguar_move := .Dogs_Turn in flags || .Last_Move_Was_Capture in flags

    border,_ := configs["border_size"].(f32)

    start := vertices[last_move[0]]
    end   := vertices[last_move[1]]

    color,_ := configs["last_move_color"].(u32)
    if over, ok := find_jump(last_move[0], last_move[1]); ok {
        rl.DrawLineEx(start, vertices[over], 4, rl.GetColor(color))
        rl.DrawLineEx(end,   vertices[over], 4, rl.GetColor(color))
    } else {
        rl.DrawLineEx(start, end, 4, rl.GetColor(color))
    }

    rl.DrawCircleV(start, vertex_size, rl.GetColor(color))
    if is_jaguar_move {
        rl.DrawRing(end, jaguar_size, jaguar_size + border * 1.2,
        0, 360, 0, rl.GetColor(color))
    } else if last_dog_move != {0, 0} {
        rect := rl.Rectangle {
            end.x - dog_size/2 - border,
            end.y - dog_size/2 - border,
            dog_size + border* 2, dog_size + border* 2,
        }
        rl.DrawRectangleLinesEx(rect, border * 1.3, rl.GetColor(color))
    }
}

render_rules :: proc(assets: Assets) {
    rl.ClearBackground(rl.GetColor(configs["bg_color"].(u32)))

    rules_text := []cstring {
    "2 jogadores jogam em turnos: ",
    "",
    "um com a Onça:",
    "",
    "o outro com os Cachorros:",
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

    font_size: f32 = UNIT * 0.3
    w := SCREEN_WIDTH/2  - BOARD_WIDTH/2
    h := SCREEN_HEIGHT/2 - BOARD_HEIGHT/2 - font_size

    for line, idx in rules_text {
        switch idx {
        case 2:
            jaguar_size,_  := configs["jaguar_size"].(f32)
            color,_ := configs["jaguar_color"].(u32)
            jaguar_size *= UNIT
            padding := 0.2 * UNIT
            mesg_size := rl.MeasureTextEx(assets.font, "um com a Onça:", font_size, 0)  
            pos := rl.Vector2 {
                w + mesg_size.x + jaguar_size + padding,
                h + mesg_size.y + jaguar_size * 0.5
            }
            rl.DrawCircleV(pos, jaguar_size, rl.GetColor(color))

        case 4:
            dog_size,_ := configs["dog_size"].(f32)
            color,_    := configs["dog_color"].(u32)
            dog_size *= UNIT
            padding := 0.2 * UNIT
            mesg_size := rl.MeasureTextEx(assets.font, "o outro com os Cachorros", font_size, 0)  
            rect := rl.Rectangle {
                w + mesg_size.x + dog_size + padding,
                h + mesg_size.y,
                dog_size,
                dog_size,
            }
            rl.DrawRectangleRec(rect, rl.GetColor(color))
        }
        h += font_size * 0.75
        rl.DrawTextEx(assets.font, line, rl.Vector2{w, h}, font_size, 1, rl.RAYWHITE)
    }

    

    render_button("Voltar", configs["line_size"].(f32), rules_rect, .Button_Hover in flags, assets)
}


render_victory :: proc (piece: Piece, assets: Assets) {
    mesg1, mesg2: cstring
    color: rl.Color

    switch piece {

    case .Jaguar:
        mesg1, mesg2 = "A ONCA", "GANHOU"
        color = rl.GetColor(configs["jaguar_color"].(u32))

    case .Dog:
        mesg1, mesg2 = "OS CÃES", "GANHARAM"
        color = rl.GetColor(configs["dog_color"].(u32))

    case .None: return
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

build_topology :: proc() {
    link :: proc(a, b: int) {
        adjacencies[a] += {b}
        adjacencies[b] += {a}
    }
    add_jump :: proc(from, over, to: int) {
        append(&JUMPS, Jump{from, over, to}, Jump{to, over, from})
    }

    for line in LINES {
        for i in 0 ..< len(line)-1 do link(line[i], line[i+1])
        for i in 0 ..< len(line)-2 do add_jump(line[i], line[i+1], line[i+2])
    }
    for j in BENT_JUMPS do add_jump(j.from, j.over, j.to)
}

find_jump :: proc(from, to: int) -> (over: int, ok: bool) {
    for j in JUMPS {
        if j.from == from && j.to == to do return j.over, true
    }
    return -1, false
}

// Constants
CONFIG_PATH :: "onca.cfg"

configs := map[string] union{f32, u32} {
    "scale"            = f32(90),
    "screen_width"     = f32(1200),
    "screen_height"    = f32(800),

    "border_size"      = f32(8),
    "line_size"        = f32(4),
    "vertex_size"      = f32(0.06),
    "dog_size"         = f32(0.18),
    "jaguar_size"      = f32(0.18),

    "bg_color"         = u32(0x160802ff),
    "fg_color"         = u32(0xd8a71eff),
    "button_bg_color"  = u32(0x160802ff),
    "button_fg_color"  = u32(0xd8a71eff),
    "dog_color"        = u32(0x473d2fff),
    "jaguar_color"     = u32(0xf2cf46ff),
    "highlight_color"  = u32(0x0fa0b0ff),
    "last_move_color"  = u32(0x10aa10ff),
}

SCALE:         f32 = configs["scale"].(f32) / 100
SCREEN_WIDTH:  f32 = configs["screen_width"].(f32)
SCREEN_HEIGHT: f32 = configs["screen_height"].(f32)
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

NUM_VERTS :: 31

Piece :: enum u8 {None, Dog, Jaguar}

INITIAL_BOARD :: [NUM_VERTS]Piece {
    00 ..< 12        = .Dog,
    12               = .Jaguar,
    13 ..< 15        = .Dog,
    15 ..< NUM_VERTS = .None,
}
BOARD := INITIAL_BOARD
jaguar_idx       := 12
drag_from        := -1
last_jaguar_move := [2]int{}
last_dog_move    := [2]int{}
score: u8 = '0'

Jump :: struct { from, over, to: int }

LINES := [?][]int {
    // rows
    {0, 1, 2, 3, 4}, {5, 6, 7, 8, 9}, {10, 11, 12, 13, 14}, {15, 16, 17, 18, 19}, {20, 21, 22, 23, 24},
    // columns (the middle one runs through the triangle)
    {0, 5, 10, 15, 20}, {1, 6, 11, 16, 21}, {2, 7, 12, 17, 22, 26, 29}, {3, 8, 13, 18, 23}, {4, 9, 14, 19, 24},
    // square diagonals
    {0, 6, 12, 18, 24}, {4, 8, 12, 16, 20}, {2, 6, 10}, {2, 8, 14}, {10, 16, 22}, {14, 18, 22},
    // triangle edges
    {22, 25, 28}, {22, 27, 30}, {25, 26, 27}, {28, 29, 30},
}

BENT_JUMPS :: [?]Jump { {16, 22, 27}, {18, 22, 25} }
JUMPS: [dynamic; 96]Jump

Adjacency :: [31]bit_set[0..<31]
adjacencies: Adjacency

Assets :: struct {
    sfx_move:    rl.Sound,
    sfx_capture: rl.Sound,
    bgm:         rl.Music,
    font:        rl.Font,
}

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
[ ] Draw Highlight around pieces on rules
[ ] Better Colors
[ ] Implement images for the rules

@BUGS:
[] after restart dragging pieces does not work

@REFACTOR:
[ ] collapse data into game_state, input and render structs
[ ] refactor highlight last_move and highlight on hover code
[ ] refactor button logic
[ ] render_highlight_around does not seem useful

[ ] Implement Skip button after captures ???
[ ] animation for piece capture @VISUAL
[ ] Change highlight color for piece that could be captured on a possible move
[ ] recompute rects, triangles, and lines for rendering the board only on resize
[ ] implement networking
[ ] implement computer AI

*/

