package core

// A small QR code writer: byte mode, error correction level M, versions 1 to
// 6 (up to 106 bytes), which is plenty for a local address with a key.

var (
	qrTotal  = [7]int{0, 26, 44, 70, 100, 134, 172} // codewords in each version
	qrEC     = [7]int{0, 10, 16, 26, 18, 24, 16}    // error correction codewords per block (level M)
	qrBlocks = [7]int{0, 1, 1, 1, 2, 2, 4}
)

// QR returns the modules of a QR code holding text (true = dark), without
// the quiet zone, or nil when the text is too long.
func QR(text string) [][]bool {
	data := []byte(text)
	ver := 0
	for v := 1; v <= 6; v++ {
		if len(data)+2 <= qrTotal[v]-qrEC[v]*qrBlocks[v] { // 12 bits of header round up to 2 bytes
			ver = v
			break
		}
	}
	if ver == 0 {
		return nil
	}
	nData := qrTotal[ver] - qrEC[ver]*qrBlocks[ver]

	// the bit stream: mode, length, bytes, terminator, padding
	var bits []bool
	put := func(v, n int) {
		for i := n - 1; i >= 0; i-- {
			bits = append(bits, v>>i&1 == 1)
		}
	}
	put(4, 4)
	put(len(data), 8)
	for _, b := range data {
		put(int(b), 8)
	}
	for i := 0; i < 4 && len(bits) < nData*8; i++ {
		bits = append(bits, false)
	}
	for len(bits)%8 != 0 {
		bits = append(bits, false)
	}
	for pad := 0xEC; len(bits) < nData*8; pad ^= 0xEC ^ 0x11 {
		put(pad, 8)
	}
	cw := make([]byte, nData)
	for i, b := range bits {
		if b {
			cw[i/8] |= 0x80 >> (i % 8)
		}
	}

	// blocks, each with its error correction, then interleaved
	nb, per := qrBlocks[ver], nData/qrBlocks[ver]
	gen := rsGenerator(qrEC[ver])
	var dBlocks, eBlocks [][]byte
	for b := 0; b < nb; b++ {
		d := cw[b*per : (b+1)*per]
		dBlocks = append(dBlocks, d)
		eBlocks = append(eBlocks, rsRemainder(d, gen))
	}
	var out []byte
	for i := 0; i < per; i++ {
		for b := 0; b < nb; b++ {
			out = append(out, dBlocks[b][i])
		}
	}
	for i := 0; i < qrEC[ver]; i++ {
		for b := 0; b < nb; b++ {
			out = append(out, eBlocks[b][i])
		}
	}

	size := 17 + 4*ver
	m := make([][]bool, size)  // modules, m[y][x]
	fn := make([][]bool, size) // function modules: not data, not masked
	for i := range m {
		m[i], fn[i] = make([]bool, size), make([]bool, size)
	}
	set := func(x, y int, dark bool) {
		if x >= 0 && y >= 0 && x < size && y < size {
			m[y][x], fn[y][x] = dark, true
		}
	}
	finder := func(cx, cy int) {
		for dy := -4; dy <= 4; dy++ {
			for dx := -4; dx <= 4; dx++ {
				d := max(abs(dx), abs(dy))
				set(cx+dx, cy+dy, d != 2 && d != 4)
			}
		}
	}
	finder(3, 3)
	finder(size-4, 3)
	finder(3, size-4)
	if ver >= 2 { // one alignment pattern for versions 2 to 6
		c := size - 7
		for dy := -2; dy <= 2; dy++ {
			for dx := -2; dx <= 2; dx++ {
				set(c+dx, c+dy, max(abs(dx), abs(dy)) != 1)
			}
		}
	}
	for i := 8; i < size-8; i++ { // timing
		set(i, 6, i%2 == 0)
		set(6, i, i%2 == 0)
	}
	format := func(mask int) {
		data := mask // level M is 00
		rem := data
		for i := 0; i < 10; i++ {
			rem = rem<<1 ^ (rem>>9)*0x537
		}
		b := (data<<10 | rem) ^ 0x5412
		bit := func(i int) bool { return b>>i&1 == 1 }
		for i := 0; i <= 5; i++ {
			set(8, i, bit(i))
		}
		set(8, 7, bit(6))
		set(8, 8, bit(7))
		set(7, 8, bit(8))
		for i := 9; i < 15; i++ {
			set(14-i, 8, bit(i))
		}
		for i := 0; i < 8; i++ {
			set(size-1-i, 8, bit(i))
		}
		for i := 8; i < 15; i++ {
			set(8, size-15+i, bit(i))
		}
		set(8, size-8, true)
	}
	format(0) // reserves the format area

	// the data, zigzag from the bottom right
	i := 0
	for right := size - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		for v := 0; v < size; v++ {
			for j := 0; j < 2; j++ {
				x := right - j
				up := (right+1)&2 == 0
				y := v
				if up {
					y = size - 1 - v
				}
				if !fn[y][x] && i < len(out)*8 {
					m[y][x] = out[i/8]>>(7-i%8)&1 == 1
					i++
				}
			}
		}
	}

	masks := [8]func(x, y int) bool{
		func(x, y int) bool { return (x+y)%2 == 0 },
		func(x, y int) bool { return y%2 == 0 },
		func(x, y int) bool { return x%3 == 0 },
		func(x, y int) bool { return (x+y)%3 == 0 },
		func(x, y int) bool { return (x/3+y/2)%2 == 0 },
		func(x, y int) bool { return x*y%2+x*y%3 == 0 },
		func(x, y int) bool { return (x*y%2+x*y%3)%2 == 0 },
		func(x, y int) bool { return ((x+y)%2+x*y%3)%2 == 0 },
	}
	apply := func(k int) {
		for y := 0; y < size; y++ {
			for x := 0; x < size; x++ {
				if !fn[y][x] && masks[k](x, y) {
					m[y][x] = !m[y][x]
				}
			}
		}
	}
	best, bestScore := 0, -1
	for k := 0; k < 8; k++ {
		apply(k)
		format(k)
		if s := qrPenalty(m); bestScore < 0 || s < bestScore {
			best, bestScore = k, s
		}
		apply(k) // the mask undoes itself
	}
	apply(best)
	format(best)
	return m
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// qrPenalty scores a masked code the way the standard does: lower reads better.
func qrPenalty(m [][]bool) int {
	n, score, dark := len(m), 0, 0
	line := func(get func(i int) bool) {
		run, last := 0, false
		for i := 0; i < n; i++ {
			c := get(i)
			if i > 0 && c == last {
				run++
			} else {
				run = 1
			}
			if run == 5 {
				score += 3
			} else if run > 5 {
				score++
			}
			last = c
		}
		// a finder look-alike: dark light dark-dark-dark light dark with four light beside it
		for i := 0; i+10 < n+0 && i+11 <= n; i++ {
			p := [11]bool{}
			for k := range p {
				p[k] = get(i + k)
			}
			a := [11]bool{true, false, true, true, true, false, true, false, false, false, false}
			b := [11]bool{false, false, false, false, true, false, true, true, true, false, true}
			if p == a || p == b {
				score += 40
			}
		}
	}
	for y := 0; y < n; y++ {
		line(func(i int) bool { return m[y][i] })
	}
	for x := 0; x < n; x++ {
		line(func(i int) bool { return m[i][x] })
	}
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			if m[y][x] {
				dark++
			}
			if x+1 < n && y+1 < n && m[y][x] == m[y][x+1] && m[y][x] == m[y+1][x] && m[y][x] == m[y+1][x+1] {
				score += 3
			}
		}
	}
	score += abs(dark*20-n*n*10) / (n * n) * 10
	return score
}

// arithmetic in GF(256) with the QR polynomial x^8+x^4+x^3+x^2+1
func gfMul(a, b byte) byte {
	var r int
	x, y := int(a), int(b)
	for i := 7; i >= 0; i-- {
		r = r<<1 ^ (r>>7)*0x11D
		if y>>i&1 == 1 {
			r ^= x
		}
	}
	return byte(r)
}

// rsGenerator is the Reed-Solomon generator polynomial of the given degree
// (its leading 1 left out).
func rsGenerator(degree int) []byte {
	g := make([]byte, degree)
	g[degree-1] = 1
	root := byte(1)
	for i := 0; i < degree; i++ {
		for j := 0; j < degree; j++ {
			g[j] = gfMul(g[j], root)
			if j+1 < degree {
				g[j] ^= g[j+1]
			}
		}
		root = gfMul(root, 2)
	}
	return g
}

func rsRemainder(data, gen []byte) []byte {
	rem := make([]byte, len(gen))
	for _, b := range data {
		f := b ^ rem[0]
		copy(rem, rem[1:])
		rem[len(rem)-1] = 0
		for i := range rem {
			rem[i] ^= gfMul(gen[i], f)
		}
	}
	return rem
}
