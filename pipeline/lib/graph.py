from collections import defaultdict


def components(pairs):
    parent = {}

    def root(one):
        parent.setdefault(one, one)
        while parent[one] != one:
            parent[one] = parent[parent[one]]
            one = parent[one]
        return one

    for a, b in pairs:
        parent[root(a)] = root(b)
    groups = defaultdict(set)
    for one in list(parent):
        groups[root(one)].add(one)
    return sorted(groups.values(), key=lambda group: (-len(group), min(group)))
