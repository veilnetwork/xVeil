package network.veil.xveil

fun main() {
    val gate = QuickUnlockReadGate<Any>()
    val a = Any(); val b = Any()
    check(gate.begin(a))
    check(!gate.begin(b))
    check(!gate.finish(b))
    check(gate.owns(a))
    check(gate.finish(a))
    check(!gate.finish(a))
    check(gate.begin(b))
    check(!gate.finish(a)) // late prior success cannot release replacement
    check(gate.cancel() === b)
    check(!gate.finish(b)) // cancelled prompt cannot release a secret
    check(gate.begin(a))
    check(gate.close() === a)
    check(!gate.finish(a)) // disposed activity cannot receive a late result
    check(!gate.begin(b))
    check(gate.close() == null)
    println("QuickUnlockReadGate: ownership, overlap, repeat, cancel and dispose passed")
}
