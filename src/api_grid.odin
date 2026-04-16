package main

// ============================================================================
// Datagrid Type And Helpers
// ============================================================================

// Datagrid is a dense 2D integer grid with fixed dimensions.
// Storage is flat row-major: len(cells) == width * height.
Datagrid :: struct {
    width:  int,
    height: int,
    cells:  []i32,
}

// new_datagrid allocates a zero-initialized datagrid of fixed size.
// Assumes width and height were already validated by the caller.
new_datagrid :: proc(width, height: int) -> Datagrid {
    return Datagrid{
        width  = width,
        height = height,
        cells  = make([]i32, width * height),
    }
}

// clone_datagrid duplicates a datagrid and all of its cell values.
clone_datagrid :: proc(src: ^Datagrid) -> Datagrid {
    dst := new_datagrid(src.width, src.height)

    for i in 0..<len(src.cells) {
        dst.cells[i] = src.cells[i]
    }

    return dst
}

// delete_datagrid releases the backing cell storage and clears the handle.
delete_datagrid :: proc(g: ^Datagrid) {
    delete(g.cells)
    g.cells = nil
    g.width = 0
    g.height = 0
}

// cell_in_datagrid_bounds reports whether (x, y) is a valid cell coordinate.
cell_in_datagrid_bounds :: proc(g: ^Datagrid, x, y: int) -> bool {
    return x >= 0 && x < g.width && y >= 0 && y < g.height
}

// datagrid_cell_to_idx converts (x, y) cell coordinates into a flat row-major index.
// Assumes coordinates are already known-valid.
datagrid_cell_to_idx :: proc(g: ^Datagrid, x, y: int) -> int {
    return y * g.width + x
}

// get_datagrid_cell returns the cell value at (x, y).
// Assumes coordinates are already known-valid.
get_datagrid_cell :: proc(g: ^Datagrid, x, y: int) -> i32 {
    return g.cells[datagrid_cell_to_idx(g, x, y)]
}

// set_datagrid_cell writes value to the cell at (x, y).
// Assumes coordinates are already known-valid.
set_datagrid_cell :: proc(g: ^Datagrid, x, y: int, value: i32) {
    g.cells[datagrid_cell_to_idx(g, x, y)] = value
}

// fill_datagrid overwrites every cell with the same value.
fill_datagrid :: proc(g: ^Datagrid, value: i32) {
    for i in 0..<len(g.cells) {
        g.cells[i] = value
    }
}