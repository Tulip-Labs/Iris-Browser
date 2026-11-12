package ui

// Icon is a line icon on a 24-unit grid, drawn as vector paths with round ends
// so it stays crisp and even at every size.
type Icon uint8

const (
	IPlay Icon = iota
	IPause
	IStepInto
	IStepOver
	IStepOut
	IStepBack
	IReset
	IPlus
	ITrash
	IEdit
	INew
	IOpen
	ISave
	IUndo
	IRedo
	IZoomIn
	IZoomOut
	IFit
	IFlowDown
	IFlowRight
	ICode
	IConsole
	IVars
	IMemory
	IDebug
	IDatabase
	IHistory
	IPalette
	IClose
	IChevron
	IChevronDown
	IChevronLeft
	IExport
	ICopy
	IFunction
	IClass
	IBook
	ICheck
	IMenu
	IDot
	ISpeed
	IEye
	IStop
	IChart
	IText
	ISplit
	ISearch
	IWarning
	IInfo
	ILab
	ISettings
	IKeyboard
	IMore
	ILock
	IShield
	IPrivate
	IContainer
	IHome
	ISparkle
	IGlobe
	IMinimize
	IMaximize
	IRestore
	ITabsVertical
	ITabsTop
	IVolume
	IMute
	IMemory2
	IImage
	IVideo
	IYouTube
	iconCount
)

// DrawIcon draws icon in the box (x, y, size, size).
func DrawIcon(g Gfx, icon Icon, x, y, size float32, c Color) {
	s := size / 24
	w := max(1.2, 1.9*s)
	X := func(v float32) float32 { return x + v*s }
	Y := func(v float32) float32 { return y + v*s }
	path := func(xy ...float32) *Path { // polyline in grid units
		p := NewPath().MoveTo(X(xy[0]), Y(xy[1]))
		for i := 2; i+1 < len(xy); i += 2 {
			p.LineTo(X(xy[i]), Y(xy[i+1]))
		}
		return p
	}
	stroke := func(xy ...float32) { Pen(g, path(xy...), w, c) }
	shape := func(xy ...float32) { // closed outline with round joins
		p := path(xy...).Close()
		g.StrokePath(p, w, c)
	}
	fill := func(xy ...float32) {
		p := path(xy...).Close()
		g.FillPath(p, c)
		g.StrokePath(p, w*0.6, c) // soften the corners
	}
	circle := func(cx, cy, r float32, filled bool) {
		rc := Rect{X(cx - r), Y(cy - r), 2 * r * s, 2 * r * s}
		if filled {
			FillOval(g, rc, c)
		} else {
			StrokeOval(g, rc, w, c)
		}
	}
	box := func(x0, y0, x1, y1, r float32) {
		StrokeRound(g, Rect{X(x0), Y(y0), (x1 - x0) * s, (y1 - y0) * s}, r*s, w, c)
	}
	solid := func(x0, y0, x1, y1, r float32) {
		FillRound(g, Rect{X(x0), Y(y0), (x1 - x0) * s, (y1 - y0) * s}, r*s, c)
	}
	arc := func(cx, cy, r, a0, a1 float32) { Pen(g, NewPath().Arc(X(cx), Y(cy), r*s, a0, a1, true), w, c) }
	// arrowhead: a small open chevron whose tip is at (tx, ty) pointing along (dx, dy)
	head := func(tx, ty, dx, dy, k float32) {
		px, py := -dy, dx
		stroke(tx-dx*k+px*k, ty-dy*k+py*k, tx, ty, tx-dx*k-px*k, ty-dy*k-py*k)
	}
	switch icon {
	case IPlay:
		fill(7.5, 5, 18.5, 12, 7.5, 19)
	case IPause:
		solid(6.5, 5, 10, 19, 1.4)
		solid(14, 5, 17.5, 19, 1.4)
	case IStop:
		solid(6, 6, 18, 18, 2.5)
	case IStepInto: // down into a dot
		stroke(12, 3.5, 12, 14)
		head(12, 14.5, 0, 1, 4)
		circle(12, 20, 1.9, true)
	case IStepOver: // arc over a dot
		Pen(g, NewPath().Arc(X(12), Y(13), 7*s, 190, 340, true), w, c)
		head(18.6, 10.6, 0.34, 0.94, 3.6)
		circle(12, 19.5, 1.9, true)
	case IStepOut: // up and out of a dot
		stroke(12, 15, 12, 4)
		head(12, 3.5, 0, -1, 4)
		circle(12, 20, 1.9, true)
	case IStepBack: // bar and left triangle
		solid(5, 5.5, 7.6, 18.5, 1.2)
		fill(18.5, 5.5, 9.5, 12, 18.5, 18.5)
	case IReset: // circular arrow (refresh)
		arc(12, 12, 7.5, -60, 235)
		head(7.7, 5.86, 0.82, -0.57, 3.4)
	case IPlus:
		stroke(12, 5, 12, 19)
		stroke(5, 12, 19, 12)
	case ITrash:
		stroke(4.5, 6.5, 19.5, 6.5)
		stroke(9.5, 6.5, 9.5, 4, 14.5, 4, 14.5, 6.5)
		shape(6.5, 6.5, 7.5, 20, 16.5, 20, 17.5, 6.5)
		stroke(10.3, 10.5, 10.3, 16.5)
		stroke(13.7, 10.5, 13.7, 16.5)
	case IEdit:
		shape(4.5, 19.5, 5.3, 15.6, 15.6, 5.3, 18.7, 8.4, 8.4, 18.7)
		stroke(13.4, 7.5, 16.5, 10.6)
	case INew:
		shape(6, 3.5, 13.5, 3.5, 18.5, 8.5, 18.5, 20.5, 6, 20.5)
		stroke(13.5, 3.5, 13.5, 8.5, 18.5, 8.5)
		stroke(12.2, 11.5, 12.2, 17.5)
		stroke(9.2, 14.5, 15.2, 14.5)
	case IOpen:
		shape(3.5, 6, 3.5, 18.5, 18, 18.5, 20.5, 10.5, 9, 10.5, 9, 10.5)
		stroke(3.5, 18.5, 3.5, 5, 9, 5, 11, 7, 17.5, 7, 17.5, 10.5)
	case ISave:
		shape(4.5, 4.5, 16.5, 4.5, 19.5, 7.5, 19.5, 19.5, 4.5, 19.5)
		stroke(8, 4.5, 8, 9, 15, 9, 15, 4.5)
		box(7.5, 13, 16.5, 19.5, 1)
	case IUndo: // arrow turning back left
		Pen(g, NewPath().MoveTo(X(5), Y(10)).LineTo(X(14), Y(10)).Arc(X(14), Y(14.5), 4.5*s, -90, 90, false).LineTo(X(9), Y(19)), w, c)
		head(4.6, 10, -1, 0, 3.6)
	case IRedo:
		Pen(g, NewPath().MoveTo(X(19), Y(10)).LineTo(X(10), Y(10)).Arc(X(10), Y(14.5), 4.5*s, 270, 90, false).LineTo(X(15), Y(19)), w, c)
		head(19.4, 10, 1, 0, 3.6)
	case IChevronLeft: // back
		stroke(15, 5, 8, 12, 15, 19)
	case IChevron: // forward
		stroke(9, 5, 16, 12, 9, 19)
	case IChevronDown:
		stroke(5, 9, 12, 16, 19, 9)
	case IZoomIn, IZoomOut, ISearch:
		circle(10.5, 10.5, 6, false)
		stroke(15, 15, 20, 20)
		if icon != ISearch {
			stroke(8, 10.5, 13, 10.5)
		}
		if icon == IZoomIn {
			stroke(10.5, 8, 10.5, 13)
		}
	case IFit:
		stroke(4, 9, 4, 4, 9, 4)
		stroke(15, 4, 20, 4, 20, 9)
		stroke(20, 15, 20, 20, 15, 20)
		stroke(9, 20, 4, 20, 4, 15)
	case IFlowDown:
		box(7, 2.5, 17, 7.5, 2)
		stroke(12, 7.5, 12, 15.5)
		head(12, 16, 0, 1, 2.8)
		box(7, 16.5, 17, 21.5, 2)
	case IFlowRight:
		box(2.5, 7, 7.5, 17, 2)
		stroke(7.5, 12, 15.5, 12)
		head(16, 12, 1, 0, 2.8)
		box(16.5, 7, 21.5, 17, 2)
	case ICode:
		stroke(8, 6.5, 3, 12, 8, 17.5)
		stroke(16, 6.5, 21, 12, 16, 17.5)
		stroke(13.5, 5, 10.5, 19)
	case IConsole:
		box(3, 4.5, 21, 19.5, 3)
		stroke(7, 9.5, 10, 12, 7, 14.5)
		stroke(12, 15, 17, 15)
	case IVars:
		box(3, 5, 21, 19, 3)
		stroke(3, 10, 21, 10)
		stroke(3, 14.5, 21, 14.5)
		stroke(10, 5, 10, 19)
	case IMemory:
		box(3, 3.5, 10.5, 11, 2)
		box(13.5, 13, 21, 20.5, 2)
		Pen(g, NewPath().MoveTo(X(10.5), Y(7.25)).LineTo(X(14.5), Y(7.25)).QuadTo(X(17.25), Y(7.25), X(17.25), Y(10)).LineTo(X(17.25), Y(12.4)), w, c)
		head(17.25, 12.6, 0, 1, 2.6)
	case IDebug:
		StrokeRound(g, Rect{X(7.5), Y(7.5), 9 * s, 12.5 * s}, 4.5*s, w, c)
		stroke(12, 11, 12, 20)
		stroke(3.5, 11, 7.5, 12)
		stroke(20.5, 11, 16.5, 12)
		stroke(3.5, 18, 7.5, 16.5)
		stroke(20.5, 18, 16.5, 16.5)
		stroke(9.5, 8, 8, 4.5)
		stroke(14.5, 8, 16, 4.5)
	case IDatabase:
		StrokeOval(g, Rect{X(4.5), Y(3), 15 * s, 5.5 * s}, w, c)
		stroke(4.5, 5.75, 4.5, 18.25)
		stroke(19.5, 5.75, 19.5, 18.25)
		g.StrokePath(NewPath().MoveTo(X(4.5), Y(12)).CubeTo(X(4.5), Y(15.6), X(19.5), Y(15.6), X(19.5), Y(12)), w, c)
		g.StrokePath(NewPath().MoveTo(X(4.5), Y(18.25)).CubeTo(X(4.5), Y(21.9), X(19.5), Y(21.9), X(19.5), Y(18.25)), w, c)
	case IHistory:
		arc(12, 12, 8, 200, 500)
		head(4.48, 9.26, -0.34, 0.94, 3)
		stroke(12, 7.5, 12, 12, 15, 14)
	case IPalette:
		g.StrokePath(NewPath().MoveTo(X(12), Y(3.5)).CubeTo(X(17), Y(3.5), X(20.5), Y(7), X(20.5), Y(11)).CubeTo(X(20.5), Y(14.5), X(17.5), Y(15), X(15.5), Y(15)).
			CubeTo(X(13.5), Y(15), X(13), Y(17), X(14), Y(18.5)).CubeTo(X(15), Y(20), X(13.5), Y(20.5), X(12), Y(20.5)).
			CubeTo(X(7), Y(20.5), X(3.5), Y(16.6), X(3.5), Y(12)).CubeTo(X(3.5), Y(7.3), X(7.3), Y(3.5), X(12), Y(3.5)).Close(), w, c)
		circle(8, 11, 1.4, true)
		circle(11.5, 7.5, 1.4, true)
		circle(16, 9, 1.4, true)
	case IClose:
		stroke(6.5, 6.5, 17.5, 17.5)
		stroke(17.5, 6.5, 6.5, 17.5)
	case IExport:
		stroke(12, 3.5, 12, 14.5)
		head(12, 15, 0, 1, 4)
		stroke(4.5, 15, 4.5, 19.5, 19.5, 19.5, 19.5, 15)
	case ICopy:
		box(8.5, 8.5, 19.5, 19.5, 2.5)
		stroke(5.5, 15, 4.5, 15, 4.5, 4.5, 15, 4.5, 15, 5.5)
	case IFunction:
		Pen(g, NewPath().MoveTo(X(16.5), Y(5)).CubeTo(X(13.5), Y(3.5), X(11.5), Y(5), X(11), Y(8)).LineTo(X(9.6), Y(17)).CubeTo(X(9.1), Y(20), X(7.5), Y(20.6), X(6), Y(19.8)), w, c)
		stroke(7.5, 10.5, 15, 10.5)
	case IClass:
		box(4, 4, 20, 20, 2.5)
		stroke(4, 9.5, 20, 9.5)
		stroke(7.5, 13.5, 16.5, 13.5)
		stroke(7.5, 16.5, 13.5, 16.5)
	case IBook:
		Pen(g, NewPath().MoveTo(X(12), Y(6.5)).CubeTo(X(10), Y(5), X(7), Y(4.5), X(3.5), Y(5)).LineTo(X(3.5), Y(18.5)).
			CubeTo(X(7), Y(18), X(10), Y(18.5), X(12), Y(20)).CubeTo(X(14), Y(18.5), X(17), Y(18), X(20.5), Y(18.5)).
			LineTo(X(20.5), Y(5)).CubeTo(X(17), Y(4.5), X(14), Y(5), X(12), Y(6.5)), w, c)
		stroke(12, 6.5, 12, 20)
	case ICheck:
		stroke(5, 12.5, 9.8, 17.3, 19, 7)
	case IMenu:
		stroke(4.5, 7, 19.5, 7)
		stroke(4.5, 12, 19.5, 12)
		stroke(4.5, 17, 19.5, 17)
	case IDot:
		circle(12, 12, 4.5, true)
	case ISpeed:
		arc(12, 15, 8.5, 180, 360)
		stroke(12, 15, 16, 9.5)
		circle(12, 15, 1.6, true)
	case IEye:
		g.StrokePath(NewPath().MoveTo(X(2.5), Y(12)).CubeTo(X(5), Y(7), X(8.5), Y(5), X(12), Y(5)).CubeTo(X(15.5), Y(5), X(19), Y(7), X(21.5), Y(12)).
			CubeTo(X(19), Y(17), X(15.5), Y(19), X(12), Y(19)).CubeTo(X(8.5), Y(19), X(5), Y(17), X(2.5), Y(12)).Close(), w, c)
		circle(12, 12, 3, false)
	case IChart: // small flowchart: rounded top, diamond, box
		box(8.5, 2.5, 15.5, 6.5, 2)
		stroke(12, 6.5, 12, 8.5)
		shape(12, 8.5, 16, 12, 12, 15.5, 8, 12)
		stroke(12, 15.5, 12, 17.5)
		box(8.5, 17.5, 15.5, 21.5, 1)
	case IText: // lines of pseudocode
		stroke(4, 6, 14, 6)
		stroke(7, 10, 19, 10)
		stroke(7, 14, 16, 14)
		stroke(4, 18, 12, 18)
	case ISplit:
		box(3, 4.5, 21, 19.5, 2.5)
		stroke(12, 4.5, 12, 19.5)
		stroke(14.5, 9, 18.5, 9)
		stroke(14.5, 12.5, 17.5, 12.5)
	case IWarning:
		shape(12, 4, 21, 19.5, 3, 19.5)
		stroke(12, 9.5, 12, 13.5)
		circle(12, 16.6, 1.1, true)
	case IInfo:
		circle(12, 12, 8.5, false)
		stroke(12, 11, 12, 16)
		circle(12, 7.9, 1.1, true)
	case ILab: // flask
		stroke(9.5, 3.5, 14.5, 3.5)
		shape(10.3, 3.5, 10.3, 9, 4.8, 18.5, 5.6, 20.5, 18.4, 20.5, 19.2, 18.5, 13.7, 9, 13.7, 3.5)
		stroke(7.2, 14.5, 16.8, 14.5)
	case ISettings:
		circle(12, 12, 3, false)
		arc(12, 12, 7.5, 0, 360)
		for _, d := range [][4]float32{{12, 2.5, 12, 4.5}, {12, 19.5, 12, 21.5}, {2.5, 12, 4.5, 12}, {19.5, 12, 21.5, 12},
			{5.3, 5.3, 6.7, 6.7}, {17.3, 17.3, 18.7, 18.7}, {5.3, 18.7, 6.7, 17.3}, {17.3, 6.7, 18.7, 5.3}} {
			stroke(d[0], d[1], d[2], d[3])
		}
	case IMore: // three dots, vertical
		circle(12, 5.5, 1.9, true)
		circle(12, 12, 1.9, true)
		circle(12, 18.5, 1.9, true)
	case ILock:
		box(5.5, 10.5, 18.5, 20, 3)
		Pen(g, NewPath().MoveTo(X(8.5), Y(10.5)).LineTo(X(8.5), Y(8)).Arc(X(12), Y(8), 3.5*s, 180, 360, false).LineTo(X(15.5), Y(10.5)), w, c)
		circle(12, 15.2, 1.2, true)
	case IShield:
		shape(12, 3, 19.5, 6, 19.5, 11.5, 18.6, 15, 12, 21, 5.4, 15, 4.5, 11.5, 4.5, 6)
		stroke(8.8, 12, 11.2, 14.4, 15.4, 9.6)
	case IPrivate: // a calm mask: two lenses and a bridge
		g.StrokePath(NewPath().Ellipse(Rect{X(3), Y(9), 7.5 * s, 6.5 * s}), w, c)
		g.StrokePath(NewPath().Ellipse(Rect{X(13.5), Y(9), 7.5 * s, 6.5 * s}), w, c)
		Pen(g, NewPath().MoveTo(X(10.5), Y(11.5)).QuadTo(X(12), Y(10.3), X(13.5), Y(11.5)), w, c)
		stroke(4, 7, 7.5, 5)
		stroke(20, 7, 16.5, 5)
	case IContainer: // stacked layers
		shape(12, 3.5, 20.5, 8, 12, 12.5, 3.5, 8)
		stroke(3.5, 12, 12, 16.5, 20.5, 12)
		stroke(3.5, 16, 12, 20.5, 20.5, 16)
	case IHome:
		shape(4, 11, 12, 4, 20, 11, 20, 20, 4, 20)
		stroke(9.5, 20, 9.5, 14.5, 14.5, 14.5, 14.5, 20)
	case ISparkle: // AI mode: a four-point star and a small one
		fill(10, 3, 11.6, 8.4, 17, 10, 11.6, 11.6, 10, 17, 8.4, 11.6, 3, 10, 8.4, 8.4)
		fill(18, 14, 18.8, 16.2, 21, 17, 18.8, 17.8, 18, 20, 17.2, 17.8, 15, 17, 17.2, 16.2)
	case IGlobe:
		circle(12, 12, 8.5, false)
		g.StrokePath(NewPath().Ellipse(Rect{X(8), Y(3.5), 8 * s, 17 * s}), w, c)
		stroke(3.5, 12, 20.5, 12)
	case IMinimize:
		stroke(6, 12.5, 18, 12.5)
	case IMaximize:
		box(6, 6, 18, 18, 2)
	case IRestore:
		box(5, 8.5, 15.5, 19, 2)
		stroke(8.5, 5, 19, 5, 19, 15.5)
	case ITabsVertical:
		box(3, 4.5, 21, 19.5, 2.5)
		stroke(9, 4.5, 9, 19.5)
		stroke(4.8, 8.5, 7.2, 8.5)
		stroke(4.8, 11.5, 7.2, 11.5)
	case ITabsTop:
		box(3, 4.5, 21, 19.5, 2.5)
		stroke(3, 9.5, 21, 9.5)
		stroke(9, 4.5, 9, 9.5)
	case IVolume, IMute:
		fill(4, 9.5, 8, 9.5, 12.5, 5.5, 12.5, 18.5, 8, 14.5, 4, 14.5)
		if icon == IVolume {
			arc(13, 12, 3.6, -50, 50)
			arc(13, 12, 7, -50, 50)
		} else {
			stroke(15.5, 9.5, 20.5, 14.5)
			stroke(20.5, 9.5, 15.5, 14.5)
		}
	case IMemory2: // a chip
		box(6.5, 6.5, 17.5, 17.5, 2)
		for _, k := range []float32{9.5, 12, 14.5} {
			stroke(k, 3.5, k, 6.5)
			stroke(k, 17.5, k, 20.5)
			stroke(3.5, k, 6.5, k)
			stroke(17.5, k, 20.5, k)
		}
	case IImage:
		box(3.5, 5, 20.5, 19, 2.5)
		circle(9, 10, 1.6, true)
		stroke(4.5, 17.5, 10, 12.5, 13.5, 15.5, 16, 13.5, 20, 17)
	case IVideo:
		box(3, 6.5, 15.5, 17.5, 2.5)
		shape(15.5, 10.5, 21, 7.5, 21, 16.5, 15.5, 13.5)
	case IYouTube:
		StrokeRound(g, Rect{X(2.5), Y(5.5), 19 * s, 13 * s}, 4*s, w, c)
		fill(10, 9, 15.5, 12, 10, 15)
	case IKeyboard:
		box(2.5, 6, 21.5, 18, 2.5)
		for _, kx := range []float32{6, 9.33, 12.66, 16} {
			circle(kx, 10, 0.9, true)
		}
		stroke(7.5, 14.5, 16.5, 14.5)
	}
}
