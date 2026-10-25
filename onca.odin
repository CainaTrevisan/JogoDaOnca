package onca

main :: proc() {

    init_game()
    defer close_game()

    rl.PlayMusicStream(ui.assets.bgm)

    for !rl.WindowShouldClose() {
        update_configs()
        if .Mute_BGM not_in ui.flags do rl.UpdateMusicStream(ui.assets.bgm)

        update()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        if .Render_Rules in ui.flags {
            render_rules()
        } else if .CPU in ui.flags {
            render_cpu_options()
        } else {
            render_board()
            render_pieces()
        }
        free_all(context.temp_allocator)
    }
}

init_game :: proc() {
    build_topology()
    build_vert_grid()

    init_configs()

    ui.screen = { config.screen_width, config.screen_height }

    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT});
    rl.InitWindow(cast(i32) ui.screen.x, cast(i32) ui.screen.y, "Onça")

    rl.InitAudioDevice()
    init_assets()
    append(&history, game)
}

close_game :: proc() {
    rl.UnloadSound(ui.assets.sfx_move)
    rl.UnloadSound(ui.assets.sfx_capture)
    rl.UnloadMusicStream(ui.assets.bgm)
    rl.UnloadFont(ui.assets.font)

    rl.CloseWindow()
    rl.CloseAudioDevice()
}

// INPUT
mouse: rl.Vector2
drag_from        := -1
last_jaguar_move := [2]int{-1, -1}
last_dog_move    := [2]int{-1, -1}

update :: proc() {

    layout_ui()
    update_vertices()

    mouse = rl.GetMousePosition()
    ui.hot = .Screen
    if rl.IsMouseButtonUp(.LEFT) do ui.active = .Screen

    in_rules := .Render_Rules in ui.flags
    in_cpu   := .CPU in ui.flags
    in_board := !in_rules && !in_cpu

    widget :: proc(id: UI_Kind, enabled: bool) -> (hit: bool) {
        e := ui.elem[id]
        if enabled && rl.CheckCollisionPointRec(mouse, rect_from_ui_elem(id)) {
            ui.hot = id
            if rl.IsMouseButtonPressed(.LEFT) {
                ui.active = id
                hit = !e.slider
            }
        }
        if e.slider && ui.active == id {
            ui.value[id] = clamp((mouse.x - e.pos.x) / e.size.x, 0, 1)
            hit = true
        }
        return
    }

    toggle :: proc(player: ^Player_Kind) {
        player^ = .Human if player^ == .Computer else .Computer
    }

    if widget(.Rules_Button,   !in_cpu)   do ui.flags ~= {.Render_Rules}
    if widget(.CPU_Button,     !in_rules) do ui.flags ~= {.CPU}
    if widget(.Jaguar_Button,  in_cpu)    do toggle(&players[0])
    if widget(.Dog_Button,     in_cpu)    do toggle(&players[1])
    if widget(.Plus_Button,    in_cpu)    do ui.depth = clamp(ui.depth + 1, 0, 7)
    if widget(.Minus_Button,   in_cpu)    do ui.depth = clamp(ui.depth - 1, 0, 7)

    if widget(.BGM_Slider, in_cpu) {
        rl.SetMusicVolume(ui.assets.bgm, ui.value[.BGM_Slider])
    }

    if widget(.SFX_Slider, in_cpu) {
        rl.SetSoundVolume(ui.assets.sfx_capture, ui.value[.SFX_Slider])
        rl.SetSoundVolume(ui.assets.sfx_move, ui.value[.SFX_Slider])
    }

    widget(.AI_Slider, in_cpu)

    if widget(.Restart_Button, in_board) {
        drag_from        = -1
        last_jaguar_move = {-1, -1}
        last_dog_move    = {-1, -1}
        ui.flags         &= {.Mute_BGM}
        game             = INITIAL_GAME
        clear(&history)
        append(&history, game)
    }

    if rl.IsKeyPressed(.M) {
        ui.flags ~= {.Mute_BGM}
    }

    multiplier := config.collision_multiplier
    if in_board && drag_from < 0 && rl.IsMouseButtonPressed(.LEFT) {
        for piece, idx in game.board {
            hit := false
            switch piece {
            case .Jaguar: hit = rl.CheckCollisionPointCircle(mouse, vertices[idx], ui.jaguar_size * multiplier)
            case .Dog:    hit = rl.CheckCollisionPointRec(mouse, center_rect(vertices[idx], ui.dog_size * multiplier * 2))
            case .None:
            }
            if hit { drag_from = idx; break }
        }
    }

    if players[0 if game.turn == .Jaguar else 1] == .Human {

        if rl.IsMouseButtonUp(.LEFT) {
            if drag_from >= 0 {
                piece := game.board[drag_from]
                collision_size := ui.vertex_size * multiplier * 2
                moves := legal_moves(game)
                for m in moves {
                    if m.from != drag_from do continue

                    hit: bool
                    if piece == .Jaguar {
                        hit = rl.CheckCollisionCircles(mouse, ui.jaguar_size, vertices[m.to], collision_size)
                    } else {
                       hit = rl.CheckCollisionCircleRec(vertices[m.to], collision_size, center_rect(mouse, ui.dog_size))
                    }

                    if !hit do continue
                    game = play_move(game, m)
                    break
                }
            }
            drag_from = -1
        }
    } else {
        if rl.IsMouseButtonUp(.LEFT) do drag_from = -1
        if game.score == 5 || dogs_won(game) do return

        if ai_job.thread == nil {
            ai_job.game    = game
            ai_job.history = slice.clone_to_dynamic(history[:])
            ai_job.depth   = clamp(ui.depth, 0, 10)
            ai_job.started = time.now()
            ai_job.thread  = thread.create_and_start_with_data(&ai_job, ai_proc)
        }

        if !thread.is_done(ai_job.thread) ||
           time.since(ai_job.started) < time.Duration(ui.value[.AI_Slider] * 2000) * time.Millisecond {
                return
        }

        thread.destroy(ai_job.thread)
        delete(ai_job.history)
        ai_job.thread = nil
        if ai_job.game != game do return

        new_game := play_move(game, ai_job.result)
        if game == new_game {
            moves := legal_moves(game)
            if len(moves) != 0 do new_game = play_move(game, moves[0])
        }

        game = new_game
        drag_from = -1
    }

    if dogs_won(game) {
        ui.flags += {.Dogs_Won}
    }

    play_move :: proc(g: Game, m: Jump) -> Game {
        ng := apply_move(g, m)
        if ng == g do return g

        if g.turn == .Jaguar { last_jaguar_move = {m.from, m.to} }
        else                 { last_dog_move    = {m.from, m.to} }

        if m.over >= 0 do clear(&history)
        append(&history, ng)

        rl.PlaySound(ui.assets.sfx_capture if m.over >= 0 else ui.assets.sfx_move)
        return ng
    }
}

dogs_won :: proc(g: Game) -> bool {
    return g.turn == .Jaguar && len(legal_moves(g)) == 0 && g.score < 5
}

center_rect :: proc(pos: rl.Vector2, size: f32) -> rl.Rectangle {
    return {pos.x - size/2, pos.y - size/2, size, size}
}

// ----------------------------------------------------------------------------
// Game Logic
// ----------------------------------------------------------------------------
NUM_VERTS :: 31

Piece :: enum u8 {None, Dog, Jaguar}

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
JUMPS: [NUM_VERTS][dynamic;  12]Jump

Moves :: [dynamic; 128]Jump

Vertex_Set :: bit_set[0 ..< NUM_VERTS]
Adjacency  :: [NUM_VERTS]Vertex_Set
adjacencies: Adjacency

Game :: struct {
    board: [NUM_VERTS]Piece,
    jaguar: int,
    score:  u8,
    turn:   Piece,
    chain:  bool,
}

INITIAL_GAME :: Game {
    board = {
        00 ..< 12        = .Dog,
        12               = .Jaguar,
        13 ..< 15        = .Dog,
        15 ..< NUM_VERTS = .None,
    },
    jaguar = 12,
    turn   = .Jaguar,
}
game := INITIAL_GAME

Player_Kind :: enum { Human, Computer }
players: [2]Player_Kind
history: [dynamic]Game

compute_possible_captures :: proc(g: Game) -> (captures: Vertex_Set) {
    for j in JUMPS[g.jaguar] {
        if j.from          == g.jaguar &&
           g.board[j.over] == .Dog     &&
           g.board[j.to]   == .None {

            captures += {j.to}
        }
    }
    return
}

build_topology :: proc() {
    link :: proc(a, b: int) {
        adjacencies[a] += {b}
        adjacencies[b] += {a}
    }
    add_jump :: proc(from, over, to: int) {
        append(&JUMPS[from], Jump{from, over, to})
        append(&JUMPS[to],   Jump{to, over, from})
    }

    for line in LINES {
        for i in 0 ..< len(line)-1 do link(line[i], line[i+1])
        for i in 0 ..< len(line)-2 do add_jump(line[i], line[i+1], line[i+2])
    }
    for j in BENT_JUMPS do add_jump(j.from, j.over, j.to)
}

find_jump :: proc(from, to: int) -> (over: int) {
    for j in JUMPS[from] {
        if j.from == from && j.to == to do return j.over
    }
    return -1
}

update_vertices :: proc() {
    pos := ui.elem[.Board].pos
    for row, idx in vert_grid do vertices[idx] = pos + row * ui.unit
}

rect_from_ui_elem :: proc(kind: UI_Kind) -> rl.Rectangle {
    e := ui.elem[kind]
    return rl.Rectangle{e.pos.x, e.pos.y, e.size.x, e.size.y}
}

legal_moves :: proc(g: Game, exclude_captures := false) -> (moves: Moves){
    if g.score >= 5 do return

    if g.turn == .Jaguar {
        targets: Vertex_Set
        if !exclude_captures do targets += compute_possible_captures(g)
        if !g.chain do targets += adjacencies[g.jaguar]

        for move in targets {
            if g.board[move] != .None do continue
            over := find_jump(g.jaguar, move)
            append(&moves, Jump{g.jaguar, over, move})
        }
    } else {
        for piece, from in g.board {
            if piece != .Dog do continue
            for to in adjacencies[from] {
                if g.board[to] != .None do continue
                append(&moves, Jump{from, -1, to})
            }
        }
    }
    return
}

apply_move  :: proc(g: Game, j: Jump) -> Game {
    g := g

    if g.score >= 5 do return g

    if g.turn == .Dog {
        if g.board[j.from] != .Dog || j.over != -1 || g.chain do return g
    } else {
        if g.board[j.from] != .Jaguar do return g
        g.jaguar = j.to
    }

    g.board[j.from] = .None
    g.board[j.to]   = g.turn
    if j.over >= 0 {
        g.board[j.over] = .None
        g.score += 1
        g.chain = true
        if len(legal_moves(g)) == 0 {
            g.chain = false
            g.turn  = .Dog
        }
    } else {
        g.turn = .Dog if g.turn == .Jaguar else .Jaguar
    }

    return g
}

// ----------------------------------------------------------------------------
// Rendering
// ----------------------------------------------------------------------------
render_board :: proc() {
    u := ui.unit

    // Background
    rl.ClearBackground(config.bg_color)

    // Board Square
    rl.DrawRectangleRec(rect_from_ui_elem(.Square), config.fg_color)

    // Board Triangle
    t  := ui.elem[.Triangle]
    v1 := rl.Vector2{t.pos.x + t.size.x * 0.5, t.pos.y}
    v2 := rl.Vector2{t.pos.x, t.pos.y + t.size.y}
    v3 := t.pos + t.size
    rl.DrawTriangle(v1, v2, v3, config.fg_color)

    // Lines
    for i in 1 ..= 3 {
        rl.DrawLineEx(vertices[i],   vertices[20+i],  config.line_size, config.bg_color)
        rl.DrawLineEx(vertices[5*i], vertices[5*i+4], config.line_size, config.bg_color)
    }

    // Diagonal Lines
    for v in ([?]int{6, 8, 16, 18}) {
        pos := vertices[v]
        start := pos - rl.Vector2{u, u}
        end   := pos + rl.Vector2{u, u}
        rl.DrawLineEx(start, end, config.line_size, config.bg_color)

        start += rl.Vector2{2*u,0}
        end   -= rl.Vector2{2*u,0}
        rl.DrawLineEx(start, end, config.line_size, config.bg_color)
    }

    // Triangle Lines
    rl.DrawLineEx(vertices[22], vertices[29], config.line_size, config.bg_color)
    rl.DrawLineEx(vertices[25], vertices[27], config.line_size, config.bg_color)

    // Score
    color := config.score_color
    score_text := cstring(raw_data([]u8{game.score + '0', 0}))
    font_size := ui.unit * config.score_size
    rl.DrawTextEx(ui.assets.font, score_text, ui.elem[.Score].pos, font_size, 0, color);

    // Render Last Move
    render_last_move()

    highlighted: Vertex_Set
    if drag_from >= 0 {
        g := game
        g.turn = game.board[drag_from]
        for m in legal_moves(g) do if m.from == drag_from do highlighted += {m.to}
    }

    // Render vertices
    for v, idx in vertices {
        color := config.vertex_color

        last_move := last_jaguar_move if game.turn == .Dog || game.chain else
                     last_dog_move

        if idx == last_move[0] {
            color = config.last_move_color
        }

        if idx in highlighted do color = config.highlight_color

        rl.DrawCircleV(v, ui.vertex_size, color)
        render_highlight_around_circle(
            v,
            ui.vertex_size,
            config.line_size,
            config.bg_color
        )
    }

    render_status()
    render_button(.CPU_Button,     "Opções")
    render_button(.Rules_Button,   "Regras")
    render_button(.Restart_Button, "Reiniciar")
}

render_button :: proc(id: UI_Kind, label: cstring) {
    rect   := rect_from_ui_elem(id)
    color1 := config.button_fg_color
    color2 := config.button_bg_color
    if ui.hot == id do color1, color2 = color2, color1
    rl.DrawRectangleRec(rect, color1)
    render_highlight_around_rect(rect, config.line_size, config.fg_color)

    font_size: f32 = ui.unit * config.button_font_size
    text_size := rl.MeasureTextEx(ui.assets.font, label, font_size, 0)
    w := rect.x + rect.width  * 0.5 - text_size.x * 0.5
    h := rect.y + rect.height * 0.5 - font_size   * 0.5
    rl.DrawTextEx(ui.assets.font, label, rl.Vector2{w, h}, font_size, 0, color2);
}

render_slider :: proc(id: UI_Kind) {
    before := rect_from_ui_elem(id)
    after := before
    before.width *= ui.value[id]
    after.width *= 1 - ui.value[id]
    after.x += before.width
    rl.DrawRectangleRec(before, config.fg_color)
    rl.DrawRectangleRec(after,  config.rules_color)
    size := ui.vertex_size * (2.2 if ui.hot == id || ui.active == id else 1.7)
    rl.DrawCircleV({after.x, after.y + after.height * 0.5}, size, config.fg_color)
}

render_label :: proc(id: UI_Kind, text: cstring, padding := f32(0.2)) {
    e    := ui.elem[id]
    size := ui.unit * config.rules_font_size
    pos  := rl.Vector2{e.pos.x + e.size.x + ui.unit*padding, e.pos.y + e.size.y*0.5 - size*0.5}
    rl.DrawTextEx(ui.assets.font, text, pos, size, 1, config.rules_color)
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

render_pieces :: proc() {
    for piece, idx in game.board {
        if piece == .None do continue
        hl_color := rl.Color{0,0,0,255}
        if piece == .Dog {
            rect  := center_rect(vertices[idx], ui.dog_size)
            color := config.dog_color
            if idx == drag_from {
                color = rl.ColorLerp(color, config.dim_color, 0.01 * config.dim_value)
            }
            rl.DrawRectangleRec(rect, color)
            if game.turn == .Dog {
                hl_color = config.turn_color
            }
            render_highlight_around_rect(rect, config.line_size, hl_color)

        } else if piece == .Jaguar {
            color := config.jaguar_color
            if idx == drag_from {
                color = rl.ColorLerp(color, config.dim_color, 0.01 * config.dim_value)
            }
            rl.DrawCircleV(vertices[idx], ui.jaguar_size, color)
            if game.turn == .Jaguar {
                hl_color = config.turn_color
            }
            render_highlight_around_circle(
                vertices[idx],
                ui.jaguar_size,
                config.line_size,
                hl_color
            )
        }
    }

    if drag_from < 0 do return

    if game.board[drag_from] == .Dog {
        rect := center_rect(mouse, ui.dog_size)
        rl.DrawRectangleRec(rect, config.dog_color)
        render_highlight_around_rect(rect, config.line_size, config.highlight_color)

    } else if game.board[drag_from] == .Jaguar {
        rl.DrawCircleV(mouse, ui.jaguar_size, config.jaguar_color)
        render_highlight_around_circle(
            mouse,
            ui.jaguar_size,
            config.line_size,
            config.highlight_color
        )
    }
}

render_last_move :: proc() {

    last_move := last_jaguar_move if game.turn == .Dog || game.chain else
                 last_dog_move

    is_jaguar_move := game.turn == .Dog || game.chain

    border := config.last_move_size

    if last_move == {-1, -1} do return
    start := vertices[last_move[0]]
    end   := vertices[last_move[1]]

    color := config.last_move_color
    if over := find_jump(last_move[0], last_move[1]); over >= 0 {
        rl.DrawLineEx(start, vertices[over], 4, color)
        rl.DrawLineEx(end,   vertices[over], 4, color)
    } else {
        rl.DrawLineEx(start, end, 4, color)
    }

    rl.DrawCircleV(start, ui.vertex_size, color)
    if is_jaguar_move {
        rl.DrawRing(end, ui.jaguar_size, ui.jaguar_size + border * 1.2,
        0, 360, 0, color)
    } else if last_dog_move != {-1, -1} {
        rect := rl.Rectangle {
            end.x - ui.dog_size/2 - border,
            end.y - ui.dog_size/2 - border,
            ui.dog_size + border* 2, ui.dog_size + border* 2,
        }
        rl.DrawRectangleLinesEx(rect, border * 1.3, color)
    }
}

render_cpu_options :: proc() {
    rl.ClearBackground(config.bg_color)
    render_button(.CPU_Button,    "Voltar")
    render_button(.Jaguar_Button, "Humano" if players[0] == .Human else "Computador")
    render_button(.Dog_Button,    "Humano" if players[1] == .Human else "Computador")
    render_button(.Plus_Button,        "+")
    render_button(.Minus_Button,       "-")
    render_slider(.BGM_Slider)
    render_slider(.SFX_Slider)
    render_slider(.AI_Slider)
    render_label(.Jaguar_Button, "Onça")
    render_label(.Dog_Button,    "Cachorros")
    render_label(.BGM_Slider,    "Música")
    render_label(.SFX_Slider,    "Efeitos Sonoros")
    render_label(.AI_Slider,     "CPU Sleep")
    render_label(.Plus_Button,   "Nível CPU")

    depth_text := cstring(raw_data([]u8{u8(ui.depth) + '0', 0}))
    render_label(.Minus_Button,  depth_text)
}

render_rules :: proc() {
    rl.ClearBackground(config.bg_color)

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

    font_size: f32 = ui.unit * config.rules_font_size
    origin := ui.elem[.Rules_Text].pos
    w, h   := origin.x, origin.y

    for line, idx in rules_text {
        switch idx {
        case 1:
            color := config.jaguar_color
            padding := 0.2 * ui.unit
            mesg_size := rl.MeasureTextEx(ui.assets.font, "um com a Onça:", font_size, 0)
            pos := rl.Vector2 {
                w + mesg_size.x + ui.jaguar_size + padding,
                h + mesg_size.y + ui.jaguar_size * 0.5
            }
            rl.DrawCircleV(pos, ui.jaguar_size, color)
            render_highlight_around_circle(
                pos,
                ui.jaguar_size,
                config.line_size,
                config.turn_color,
            )

        case 3:
            color    := config.dog_color
            padding := 0.15 * ui.unit
            mesg_size := rl.MeasureTextEx(ui.assets.font, "o outro com os Cachorros", font_size, 0)
            rect := rl.Rectangle {
                w + mesg_size.x + ui.dog_size + padding,
                h + mesg_size.y,
                ui.dog_size,
                ui.dog_size,
            }
            rl.DrawRectangleRec(rect, color)
            render_highlight_around_rect(rect, config.line_size, config.turn_color)
        }
        rl.DrawTextEx(ui.assets.font, line, rl.Vector2{w, h}, font_size, 1, config.rules_color)
        h += font_size * 0.75
    }

    render_button(.Rules_Button, "Voltar")
}

render_status :: proc () {
    mesg1, mesg2: cstring = "ONÇA ", "JOGA"
    color  := config.jaguar_color
    color2 := config.turn_color
    if game.score == 5 {
        mesg1, mesg2 = "ONÇA ", "GANHOU"
        color2 = color
    } else if .Dogs_Won in ui.flags {
        mesg1, mesg2 = "CACHORROS ", "GANHARAM"
        color  = config.dog_color
        color2 = color
    } else if game.turn == .Dog {
        mesg1, mesg2 = "CACHORROS ", "JOGAM"
        color = config.dog_color
    }

    pos := ui.elem[.Turn_Mesg].pos
    font_size := ui.unit * config.status_font_size
    mesg1_size := rl.MeasureTextEx(ui.assets.font, mesg1, font_size, 0)
    mesg2_size := rl.MeasureTextEx(ui.assets.font, mesg2, font_size, 0)
    pos.x -= (mesg1_size.x + mesg2_size.x) * 0.5
    rl.DrawTextEx(ui.assets.font, mesg1, pos, font_size, 0, color)
    rl.DrawTextEx(ui.assets.font, mesg2, pos + {mesg1_size.x, 0}, font_size, 0, color2)
}

// ----------------------------------------------------------------------------
// UI System
// ----------------------------------------------------------------------------

// @CAUTION: UI_Kind order matters. It must be declared in the same order that layout_ui loop
// computes the ui.elem positions
UI_Kind :: enum {
    Screen,
    Turn_Mesg,
    Board,
    Square,
    Triangle,
    Score,
    Rules_Text,
    Rules_Button,
    Restart_Button,
    CPU_Button,
    Jaguar_Button,
    Dog_Button,
    BGM_Slider,
    SFX_Slider,
    AI_Slider,
    Minus_Button,
    Plus_Button,
}

UI_Elem :: struct {
    parent: UI_Kind,
    pos, size, offset: rl.Vector2,
    slider: bool,
}

UI_Flags :: enum { CPU, Dogs_Won, Mute_BGM, Render_Rules }

ui: struct {
    unit, vertex_size, jaguar_size, dog_size: f32,
    screen:       rl.Vector2,
    flags:        bit_set[UI_Flags],
    elem:         [UI_Kind]UI_Elem,
    value:        [UI_Kind]f32,
    hot, active:  UI_Kind,
    depth:        i8,
    using assets: Assets,
}

vertices:  [NUM_VERTS]rl.Vector2

vert_grid: [NUM_VERTS]rl.Vector2
build_vert_grid :: proc() {
    n := 0
    for row in 0..<5 {
        for col in 0..<5 {
            vert_grid[n] = {f32(col), f32(row)}
            n += 1
        }
    }
    for i in 0..<3 { vert_grid[n] = {1.5 + f32(i)*0.5, 5}; n += 1 }   // 25..27
    for i in 0..<3 { vert_grid[n] = {1.0 + f32(i),     6}; n += 1 }
}


layout_ui :: proc() {
    ui.screen = rl.Vector2{
        cast(f32) rl.GetScreenWidth(),
        cast(f32) rl.GetScreenHeight(),
    }
    scale := config.scale * 0.01
    ui.unit = min(ui.screen.x * scale / 4, ui.screen.y * scale / 6)
    u := ui.unit

    ui.vertex_size = config.vertex_size * u
    ui.jaguar_size = config.jaguar_size * u
    ui.dog_size    = config.dog_size * u

    board_size := rl.Vector2{4*u, 6*u}
    padding := config.status_font_size * 2.5 * u
    turn_y := ui.screen.y * 0.5 - board_size.y * 0.5 - padding * 0.7

    ui.elem[.Screen]     = {parent = .Screen,     size = ui.screen                                             }
    ui.elem[.Turn_Mesg]  = {parent = .Screen,                         offset = {ui.screen.x * 0.5,   turn_y  } }
    ui.elem[.Board]      = {parent = .Turn_Mesg,  size = board_size,  offset = {-board_size.x * 0.5, padding } }
    ui.elem[.Triangle]   = {parent = .Board,      size = {2*u, 2*u},  offset = {u, 4*u}                        }
    ui.elem[.Square]     = {parent = .Board,      size = {4*u, 4*u}                                            }
    ui.elem[.Score]      = {parent = .Turn_Mesg,                      offset = {-1.55 * u, -u*0.1}             }
    ui.elem[.Rules_Text] = {parent = .Board,                                                                   }

    w := 0.5 * u
    h := 0.35 * u
    y := 6 * u - (u - h) * 0.71
    ui.elem[.Rules_Button]   = {parent = .Board,         size = {w, h},           offset = {4*u - w, y}                }
    ui.elem[.CPU_Button]     = {parent = .Rules_Button,  size = {w, h},           offset = {0, -u*0.5}                 }
    ui.elem[.Restart_Button] = {parent = .Board,         size = {w + u*0.07, h},  offset = {0, y}                      }

    ui.elem[.Jaguar_Button]  = {parent = .Board,         size = {w + u * 0.3, h}, offset = {0, u}                      }
    ui.elem[.Dog_Button]     = {parent = .Jaguar_Button, size = {w + u * 0.3, h}, offset = {0, u*0.5}                  }
    ui.elem[.BGM_Slider]     = {parent = .Dog_Button,    size = {2*u, 0.12*u},    offset = {0, u}     , slider = true  }
    ui.elem[.SFX_Slider]     = {parent = .BGM_Slider,    size = {2*u, 0.12*u},    offset = {0, 0.5* u}, slider = true  }
    ui.elem[.AI_Slider]      = {parent = .SFX_Slider,    size = {2*u, 0.12*u},    offset = {0, 0.5* u}, slider = true  }

    ui.elem[.Minus_Button]   = {parent = .AI_Slider,     size = {w*0.5, h*0.5},   offset = {0, 0.5* u}                 }
    ui.elem[.Plus_Button]    = {parent = .Minus_Button,  size = {w*0.5, h*0.5},   offset = {0.7 * u,0}                 }

    for &e in ui.elem do e.pos = e.offset + ui.elem[e.parent].pos
}

// ----------------------------------------------------------------------------
// AI System
// ----------------------------------------------------------------------------

AI_Job :: struct {
    thread:  ^thread.Thread,  // nil = no job
    game:    Game,
    history: [dynamic]Game,
    depth:   i8,
    started: time.Time,
    result:  Jump,
}
ai_job: AI_Job

ai_proc :: proc(data: rawptr) {
    job := cast(^AI_Job) data
    _, job.result = minimax(job.game, job.depth, &job.history)
}

INF :: math.F32_MAX
minimax :: proc(g: Game, depth: i8, hist: ^[dynamic]Game, alpha := f32(-INF), beta := f32(INF)) -> (evaluation: f32, best_move: Jump) {
    g := g
    alpha, beta := alpha, beta

    maximizing := g.turn == .Jaguar
    if g.score >= 5 do return INF, {}
    if depth < 0 && !g.chain do return evaluate_position(g), {}

    moves := legal_moves(g)
    if len(moves) == 0 do return -INF, {}

    best_value: f32 = -INF if maximizing else INF
    best_move = moves[0]

    distance_between_points :: proc(a, b: rl.Vector2) -> f32 {
        return math.sqrt(math.pow2_f32(b.x - a.x) + math.pow2_f32(b.y - a.y))
    }

    Scored :: struct { move: Jump, key: f32 }
    scored: [dynamic; 128]Scored
    for m in moves {
        k: f32
        if depth >= 1 {
            k = evaluate_position(apply_move(g, m))
            if maximizing do k = -k
        } else if g.turn == .Dog {
            k = distance_between_points(vert_grid[m.to], vert_grid[g.jaguar])
        } else if m.over < 0 {
            k = 1
        }
        append(&scored, Scored{m, k + rand.float32() * config.random_threshold})
    }
    slice.sort_by(scored[:], proc(a, b: Scored) -> bool { return a.key < b.key })
    for s, i in scored do moves[i] = s.move

    for move in moves {

        child := apply_move(g, move)
        repeats := 0
        for h in hist^ {
            if child == h do repeats += 1
        }
        if move.over >= 0 do repeats = 0


        penalty := config.score_weight * 0.5
        value: f32
        if repeats == 1 {
            value += -penalty if maximizing else penalty
        } else {
            append(hist, child)
            next_depth := depth if child.chain else depth - 1
            value,_ = minimax(child, next_depth, hist, alpha, beta)
            pop(hist)
            if repeats == 1 do value += -4 if maximizing else 4
        }

        if maximizing {
            if (value > best_value) { best_value, best_move = value, move }
            alpha = max(alpha, value)
        } else {
            if (value < best_value) { best_value, best_move = value, move }
            beta = min(beta, value)
        }
        if alpha >= beta do break
    }
    return best_value, best_move
}

evaluate_position :: proc(g: Game) -> (evaluation: f32) {
    if g.score == 5 do return  INF

    jaguar_turn := g.turn == .Jaguar
    g := g
    g.turn = .Jaguar
    g.chain = false

    moves := legal_moves(g)
    if jaguar_turn && len(moves) == 0 do return -INF

    num_captures := 0
    for move in moves do if move.over >- 0 do num_captures += 1

    score    := config.score_weight   * f32(g.score)
    captures := config.capture_weight * f32(num_captures)
    possible := config.moves_weight   * f32(len(moves))

    // Number of nearby dogs
    visited := Vertex_Set{g.jaguar}
    count := 0
    for vert in adjacencies[g.jaguar] {
        for v in adjacencies[vert] {
            if g.board[v] == .Dog && v not_in visited {
                visited += {v}
                count += 1
            }
        }
    }
    dogs_nearby := config.dogs_nearby_weight * f32(count)

    // Connected Component Size from Jaguar
    visited = {g.jaguar}
    neighbors := visited

    for neighbors != {} {
        next: Vertex_Set
        for v in neighbors {
            for to in adjacencies[v] {
                if g.board[to] == .None do next += {to}
            }
        }
        neighbors = next - visited
        visited += neighbors
    }

    empty := config.space_weight * f32(card(visited) - 1)

    evaluation = score + captures + possible + empty - dogs_nearby
    return evaluation
}

// ----------------------------------------------------------------------------
// Assets System
// ----------------------------------------------------------------------------
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

init_assets :: proc() {
    // SFX
    load_sound_from_memory :: proc(sfx: ^rl.Sound, bytes: []u8) {
        wave := rl.LoadWaveFromMemory(".wav", rawptr(raw_data(bytes)), cast(i32) len(bytes))
        sfx^  = rl.LoadSoundFromWave(wave)
        rl.UnloadWave(wave)
    }
    load_sound_from_memory(&ui.assets.sfx_move,    move_bytes)
    load_sound_from_memory(&ui.assets.sfx_capture, capture_bytes)

    // BGM
    ui.assets.bgm = rl.LoadMusicStreamFromMemory(".wav", rawptr(raw_data(bgm_bytes)), cast(i32) len(bgm_bytes))

    // Font
    codepoint_count: i32 = 0
    codepoints := rl.LoadCodepoints(
        " !\"#$%&'()*+,-./0123456789:;<=>?ABCDEFGHIJKLMNOPQRSTUVWXYZÃÇ[\\]^_`abcdefghijklmnopqrstuvwxyzçéáíóúõ{|}~",
        &codepoint_count
    )
    ui.assets.font = rl.LoadFontFromMemory(".ttf", rawptr(raw_data(font_bytes)), cast(i32) len(font_bytes), 64, codepoints, codepoint_count)
    rl.UnloadCodepoints(codepoints)
}

// ----------------------------------------------------------------------------
// Config System
// ----------------------------------------------------------------------------
CONFIG_PATH :: "onca.cfg"

config: Config
Config :: struct {
    scale:                     f32 `default:"87"`,
    screen_width:              f32 `default:"800"`,
    screen_height:             f32 `default:"1000"`,
    last_move_size:            f32 `default:"10"`,
    line_size:                 f32 `default:"5"`,
    vertex_size:               f32 `default:"0.06"`,
    dog_size:                  f32 `default:"0.17"`,
    jaguar_size:               f32 `default:"0.17"`,
    score_size:                f32 `default:"0.43"`,
    button_font_size:          f32 `default:"0.19"`,
    rules_font_size:           f32 `default:"0.32"`,
    status_font_size:          f32 `default:"0.20"`,
    collision_multiplier:      f32 `default:"2.4"`,
    random_threshold:          f32 `default:"0.25"`,
    dim_value:                 f32 `default:"60"`,
    bgm_volume:                f32 `default:"80"`,
    sfx_volume:                f32 `default:"100"`,

    jaguar_player:             Player_Kind `default:"Human"`,
    dog_player:                Player_Kind `default:"Human"`,

    bg_color:                  rl.Color `default:"0x120702ff"`,
    fg_color:                  rl.Color `default:"0xd0a01eff"`,
    button_bg_color:           rl.Color `default:"0x120702ff"`,
    button_fg_color:           rl.Color `default:"0xd0a01eff"`,
    dog_color:                 rl.Color `default:"0x473d2fff"`,
    jaguar_color:              rl.Color `default:"0xf2cf46ff"`,
    highlight_color:           rl.Color `default:"0x1a71eaff"`,
    turn_color:                rl.Color `default:"0x931d00ff"`,
    last_move_color:           rl.Color `default:"0x227232ff"`,
    score_color:               rl.Color `default:"0xffffaaff"`,
    rules_color:               rl.Color `default:"0xffffaaff"`,
    vertex_color:              rl.Color `default:"0xffffaaff"`,
    dim_color:                 rl.Color `default:"0x000000ff"`,

    ai_sleep:                  int `default:"700"`,
    minimax_depth:             int `default:"2"`,
    score_weight:              f32 `default:"24.0"`,
    capture_weight:            f32 `default:"12.0"`,
    moves_weight:              f32 `default:"2.0"`,
    space_weight:              f32 `default:"4.0"`,
    dogs_nearby_weight:        f32 `default:"6.0"`,
}

init_configs :: proc() {
    for field in reflect.struct_fields_zipped(Config) {
        if v, ok := reflect.struct_tag_lookup(field.tag, "default"); ok {
            set_config(field.name, v)
        }
    }
    update_configs()
}

set_config :: proc(name, value: string) {
    field := reflect.struct_field_by_name(Config, name)
    if field.type == nil {
        fmt.printf("Config Error: %q is not a valid config name. These are the valid config names:\n", name)
        for name in reflect.struct_field_names(Config) do fmt.printf("    %v\n", name)
        fmt.println()
        return
    }

    dst := rawptr(uintptr(&config) + field.offset)

    switch field.type.id {

    case rl.Color, int:
        if v, ok := strconv.parse_int(value); ok {
            if field.type.id == int { (^int)(dst)^ = v }
            else { (^rl.Color)(dst)^ = rl.GetColor(u32(v)) }
        } else { fmt.printf("Config Error: Bad type in config %q. Must be a numeric value.\n", name) }

    case f32:
        if v, ok := strconv.parse_f32(value); ok {
            (^f32)(dst)^ = v
        } else { fmt.printf("Config Error: Bad type in config %q. Must be a numeric value.\n", name) }

    case Player_Kind:
        if      value == "Computer" { (^Player_Kind)(dst)^ = .Computer }
        else if value == "Human"    { (^Player_Kind)(dst)^ = .Human;   }
        else                        { fmt.printf("Config Error: Bad type in config %q. Must be 'Human' or 'Computer'.\n", name) }

    case:
        unreachable()
    }
}

update_configs :: proc() {
    @static frame: int
    frame += 1
    if frame % 15 != 1 do return

    stats, err := os.stat(CONFIG_PATH, context.temp_allocator)
    if err != nil {
        fmt.printf("File Error: %q: %v\n", CONFIG_PATH, err)
        return
    }

    @static last_modification: time.Time
    if stats.modification_time != last_modification {
        last_modification = stats.modification_time

        buf, err := os.read_entire_file_from_path(CONFIG_PATH, context.temp_allocator)
        if err != nil {
            fmt.printf("File Error: %q: %v\n", CONFIG_PATH, err)
            return
        }

        text := string(buf)

        for line in strings.split_lines_iterator(&text) {
            without_comment := strings.truncate_to_rune(line, '#')
            fields := strings.fields(without_comment, context.temp_allocator)
            if len(fields) == 0 do continue
            if len(fields) != 2 {
                fmt.printf("Config Error: Configs should have 2 values separated by spaces: a name and a number.\n")
                fmt.printf("              Found %v: ", len(fields))
                for field in fields do fmt.printf("%v ", field)
                fmt.println()
                continue
            }

            key, value := fields[0], fields[1]
            set_config(key, value)
        }

        ui.value[.BGM_Slider] = config.bgm_volume * 0.01
        ui.value[.SFX_Slider] = config.sfx_volume * 0.01
        ui.value[.AI_Slider]  = clamp(f32(config.ai_sleep) / 2000, 0.0, 1.0)
        ui.depth = cast(i8) clamp(config.minimax_depth, 0, 7)

        rl.SetMusicVolume(ui.assets.bgm,         clamp(ui.value[.BGM_Slider], 0.0, 1.0))
        rl.SetSoundVolume(ui.assets.sfx_capture, clamp(ui.value[.SFX_Slider], 0.0, 1.0))
        rl.SetSoundVolume(ui.assets.sfx_move,    clamp(ui.value[.SFX_Slider], 0.0, 1.0))

        players[0] = config.jaguar_player
        players[1] = config.dog_player

        fmt.printf("INFO: Configs updated from %q\n", CONFIG_PATH)
    }
}

// ----------------------------------------------------------------------------
// Dependencies
// ----------------------------------------------------------------------------
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:reflect"
import "core:os"
import "core:time"
import "core:math"
import "core:slice"
import "core:thread"
import "core:math/rand"
import rl "vendor:raylib"

// ----------------------------------------------------------------------------
// @TODO
// ----------------------------------------------------------------------------
/*

@IMPROVEMENTS
[ ] Better Colors
[ ] reorder code

@FEATURES
[ ] Implement images for the rules
[ ] Implement Skip button after captures ???
[ ] Change highlight color for piece that could be captured on a possible move
[ ] animation for piece capture @VISUAL
[ ] implement networking

@BUGS:

@REFACTOR:
[ ] render_highlight_around does not seem useful
[ ] recompute rects, triangles, and lines for rendering the board only on resize
*/
