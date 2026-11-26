dump :: proc(i: ^wl.Interface) {
	fmt.printf("%s v%d %d %d\n", i.name, i.version, i.method_count, i.event_count)
	msgs := [2][^]wl.Message{i.methods, i.events}
	counts := [2]i32{i.method_count, i.event_count}
	for k in 0 ..< 2 {
		for j in 0 ..< counts[k] {
			m := msgs[k][j]
			fmt.printf("  %s %s", m.name, m.signature)
			n := 0
			for c in string(m.signature) do if c != '?' && (c < '0' || c > '9') do n += 1
			for a in 0 ..< n {
				t := m.types == nil ? nil : m.types[a]
				fmt.printf(" %s", t == nil ? "-" : string(t.name))
			}
			fmt.printf("\n")
		}
	}
}
