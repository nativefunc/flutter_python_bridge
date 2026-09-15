import time


def add(a, b):
    return a + b


def greet(name, punctuation="。"):
    return f"你好，{name}{punctuation}"


def count(total):
    for value in range(1, total + 1):
        print(value, flush=True)
        time.sleep(0.1)
    return total
