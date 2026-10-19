"""Join endpoint-authenticated ciphertext to generic forwarding observations.

Same-host diagnostic clocks only. A transport selection is not a wire-send
observation: the following span includes transport queues and network service.
Repeated paths are rejected rather than assigned to an arbitrary attempt.
"""
import re


def attribute_route(digest, rows, *, source, receiver, sealed_us, received_us,
                    sealed_bytes):
    if not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('Missing authenticated ciphertext digest')
    if source == receiver or sealed_us < 0 or received_us < sealed_us:
        raise ValueError('Invalid endpoint route witnesses')
    selected, entered, returned = {}, {}, {}
    tables = dict(transport_selected=selected, dispatch_enter=entered,
                  dispatch_return=returned)
    for row in rows:
        if row['opaque_sha256'] != digest:
            continue
        if int(row['opaque_bytes']) != sealed_bytes:
            raise ValueError('Different opaque payload length')
        node, peer = row['node'], row['peer']
        if not all(re.fullmatch(r'[0-9a-f]{8}', x) for x in (node, peer)):
            raise ValueError('Invalid diagnostic node prefix')
        table = tables.get(row['stage'])
        if table is None or node in table:
            raise ValueError('Unknown or ambiguous route observation')
        at = int(row['monotonic_us'])
        if at < sealed_us or (row['stage'] != 'dispatch_return' and at > received_us):
            raise ValueError('Route clock outside authenticated endpoints')
        table[node] = (peer, at)
    if source in entered or receiver in selected:
        raise ValueError('Unexpected source ingress or receiver egress')
    hops, processing, visited = [], [], set()
    node, previous_us = source, sealed_us
    while node != receiver:
        if node in visited or node not in selected:
            raise ValueError('Missing or cyclic opaque route')
        visited.add(node)
        peer, at = selected[node]
        if peer not in entered or entered[peer][0] != node:
            raise ValueError('Missing or contradictory next-hop receipt')
        arrived = entered[peer][1]
        if not previous_us <= at <= arrived:
            raise ValueError('Invalid route clock order')
        if node != source:
            processing.append(dict(node=node, ingress_to_selection_ms=
                                   (at-previous_us)/1000))
        hops.append(dict(source=node, receiver=peer, selected_us=at,
                         dispatched_us=arrived,
                         selection_to_dispatch_ms=(arrived-at)/1000))
        node, previous_us = peer, arrived
    expected_receivers = (visited - {source}) | {receiver}
    if (set(selected) != visited or set(entered) != expected_receivers
            or set(returned) != set(entered)):
        raise ValueError('Incomplete or disconnected opaque route')
    # Dispatch return is a post-completion observation. It may race a later
    # transport selection, so it must not be used as that selection's start.
    for node, (peer, at) in returned.items():
        if peer != entered[node][0] or at < entered[node][1]:
            raise ValueError('Invalid dispatch return witness')
    return dict(hops=hops, relay_processing=processing,
                seal_to_first_selection_ms=(hops[0]['selected_us']-sealed_us)/1000,
                last_dispatch_to_authenticated_ms=(received_us-previous_us)/1000,
                sealed_to_authenticated_ms=(received_us-sealed_us)/1000,
                limits=[
                    'Diagnostic node prefixes must be unique in this owned fixture',
                    'Selection-to-dispatch includes queues and network; it is not pure propagation time',
                    'This join does not identify an encrypted UDP datagram or its shaper queue',
                ])
