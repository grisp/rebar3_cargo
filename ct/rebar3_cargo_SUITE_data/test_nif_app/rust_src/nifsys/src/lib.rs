use rustler::{types::atom::Atom, NifTuple};

mod atoms {
    rustler::atoms! { an_atom }
}

#[rustler::nif]
fn static_atom() -> Atom {
    atoms::an_atom()
}

/// Add two integers. `native_add(A,B) -> A+B.`
#[rustler::nif]
fn native_add(a: i64, b: i64) -> i64 {
    a + b
}

#[derive(NifTuple)]
struct AddTuple {
    e1: i32,
    e2: i32,
}

/// Add integers provided in a 2-tuple. `tuple_add({A,B}) -> A+B.`
#[rustler::nif]
fn tuple_add(tuple: AddTuple) -> i32 {
    tuple.e1 + tuple.e2
}

rustler::init!("nifsys");
