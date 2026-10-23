"""Deterministic class-balanced accumulation batches, with auditable exposure."""
import random


def balanced_order(items, draws, accumulation, seed):
    if accumulation < 2 or accumulation % 2 or draws % accumulation:
        raise ValueError("Balanced draws require even complete accumulation batches")
    pools = [[i for i, item in enumerate(items) if item["label"] == label] for label in (0, 1)]
    if not all(pools):
        raise ValueError("Both classes required")
    rng = random.Random(seed)
    queues = [[], []]
    order = []
    for _ in range(draws // accumulation):
        batch = []
        for label in (0, 1):
            for _ in range(accumulation // 2):
                if not queues[label]:
                    queues[label] = list(pools[label])
                    rng.shuffle(queues[label])
                batch.append(queues[label].pop())
        rng.shuffle(batch)
        order.extend(batch)
    return order
