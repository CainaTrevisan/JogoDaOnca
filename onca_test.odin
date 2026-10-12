#+feature global-context
package onca

import "core:testing"

@(init)
setup_topology :: proc() { build_topology() }

@(test)
topology_counts :: proc(t: ^testing.T) {
    edges := 0
    for a, v in adjacencies {
        edges += card(a)
        for w in a {
            testing.expect(t, v in adjacencies[w], "adjacency not symmetric")
        }
    }
    testing.expect_value(t, edges, 132)
    testing.expect_value(t, len(JUMPS), 96)
}

@(test)
jumps_well_formed :: proc(t: ^testing.T) {
    for j, i in JUMPS {
        testing.expect(t, j.over in adjacencies[j.from],     "over not adjacent to from")
        testing.expect(t, j.to   in adjacencies[j.over],     "to not adjacent to over")
        testing.expect(t, j.to   not_in adjacencies[j.from], "jump endpoints are adjacent")
        for k in i+1 ..< len(JUMPS) {
            testing.expect(t, !(JUMPS[k].from == j.from && JUMPS[k].to == j.to), "duplicate from/to")
        }
    }
}
