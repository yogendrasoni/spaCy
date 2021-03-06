# coding: utf-8
"""Implements the projectivize/deprojectivize mechanism in Nivre & Nilsson 2005
for doing pseudo-projective parsing implementation uses the HEAD decoration
scheme.
"""
from __future__ import unicode_literals

from copy import copy


DELIMITER = '||'


def ancestors(tokenid, heads):
    # Returns all words going from the word up the path to the root. The path
    # to root cannot be longer than the number of words in the  sentence. This
    # function ends after at most len(heads) steps, because it would otherwise
    # loop indefinitely on cycles.
    head = tokenid
    cnt = 0
    while heads[head] != head and cnt < len(heads):
        head = heads[head]
        cnt += 1
        yield head
        if head is None:
            break


def contains_cycle(heads):
    # in an acyclic tree, the path from each word following the head relation
    # upwards always ends at the root node
    for tokenid in range(len(heads)):
        seen = set([tokenid])
        for ancestor in ancestors(tokenid, heads):
            if ancestor in seen:
                return seen
            seen.add(ancestor)
    return None


def is_nonproj_arc(tokenid, heads):
    # definition (e.g. Havelka 2007): an arc h -> d, h < d is non-projective
    # if there is a token k, h < k < d such that h is not
    # an ancestor of k. Same for h -> d, h > d
    head = heads[tokenid]
    if head == tokenid:  # root arcs cannot be non-projective
        return False
    elif head is None:  # unattached tokens cannot be non-projective
        return False

    start, end = (head+1, tokenid) if head < tokenid else (tokenid+1, head)
    for k in range(start, end):
        for ancestor in ancestors(k, heads):
            if ancestor is None:  # for unattached tokens/subtrees
                break
            elif ancestor == head:  # normal case: k dominated by h
                break
        else:  # head not in ancestors: d -> h is non-projective
            return True
    return False


def is_nonproj_tree(heads):
    # a tree is non-projective if at least one arc is non-projective
    return any(is_nonproj_arc(word, heads) for word in range(len(heads)))


def decompose(label):
    return label.partition(DELIMITER)[::2]


def is_decorated(label):
    return label.find(DELIMITER) != -1


def preprocess_training_data(gold_tuples, label_freq_cutoff=30):
    preprocessed = []
    freqs = {}
    for raw_text, sents in gold_tuples:
        prepro_sents = []
        for (ids, words, tags, heads, labels, iob), ctnts in sents:
            proj_heads, deco_labels = projectivize(heads, labels)
            # set the label to ROOT for each root dependent
            deco_labels = ['ROOT' if head == i else deco_labels[i]
                           for i, head in enumerate(proj_heads)]
            # count label frequencies
            if label_freq_cutoff > 0:
                for label in deco_labels:
                    if is_decorated(label):
                        freqs[label] = freqs.get(label, 0) + 1
            prepro_sents.append(
                ((ids, words, tags, proj_heads, deco_labels, iob), ctnts))
        preprocessed.append((raw_text, prepro_sents))
    if label_freq_cutoff > 0:
        return _filter_labels(preprocessed, label_freq_cutoff, freqs)
    return preprocessed


def projectivize(heads, labels):
    # Use the algorithm by Nivre & Nilsson 2005. Assumes heads to be a proper
    # tree, i.e. connected and cycle-free. Returns a new pair (heads, labels)
    # which encode a projective and decorated tree.
    proj_heads = copy(heads)
    smallest_np_arc = _get_smallest_nonproj_arc(proj_heads)
    if smallest_np_arc is None:  # this sentence is already projective
        return proj_heads, copy(labels)
    while smallest_np_arc is not None:
        _lift(smallest_np_arc, proj_heads)
        smallest_np_arc = _get_smallest_nonproj_arc(proj_heads)
    deco_labels = _decorate(heads, proj_heads, labels)
    return proj_heads, deco_labels


def deprojectivize(tokens):
    # Reattach arcs with decorated labels (following HEAD scheme). For each
    # decorated arc X||Y, search top-down, left-to-right, breadth-first until
    # hitting a Y then make this the new head.
    for token in tokens:
        if is_decorated(token.dep_):
            newlabel, headlabel = decompose(token.dep_)
            newhead = _find_new_head(token, headlabel)
            token.head = newhead
            token.dep_ = newlabel
    return tokens


def _decorate(heads, proj_heads, labels):
    # uses decoration scheme HEAD from Nivre & Nilsson 2005
    assert(len(heads) == len(proj_heads) == len(labels))
    deco_labels = []
    for tokenid, head in enumerate(heads):
        if head != proj_heads[tokenid]:
            deco_labels.append(
                '%s%s%s' % (labels[tokenid], DELIMITER, labels[head]))
        else:
            deco_labels.append(labels[tokenid])
    return deco_labels


def _get_smallest_nonproj_arc(heads):
    # return the smallest non-proj arc or None
    # where size is defined as the distance between dep and head
    # and ties are broken left to right
    smallest_size = float('inf')
    smallest_np_arc = None
    for tokenid, head in enumerate(heads):
        size = abs(tokenid-head)
        if size < smallest_size and is_nonproj_arc(tokenid, heads):
            smallest_size = size
            smallest_np_arc = tokenid
    return smallest_np_arc


def _lift(tokenid, heads):
    # reattaches a word to it's grandfather
    head = heads[tokenid]
    ghead = heads[head]
    # attach to ghead if head isn't attached to root else attach to root
    heads[tokenid] = ghead if head != ghead else tokenid


def _find_new_head(token, headlabel):
    # search through the tree starting from the head of the given token
    # returns the id of the first descendant with the given label
    # if there is none, return the current head (no change)
    queue = [token.head]
    while queue:
        next_queue = []
        for qtoken in queue:
            for child in qtoken.children:
                if child.is_space:
                    continue
                if child == token:
                    continue
                if child.dep_ == headlabel:
                    return child
                next_queue.append(child)
        queue = next_queue
    return token.head


def _filter_labels(gold_tuples, cutoff, freqs):
    # throw away infrequent decorated labels
    # can't learn them reliably anyway and keeps label set smaller
    filtered = []
    for raw_text, sents in gold_tuples:
        filtered_sents = []
        for (ids, words, tags, heads, labels, iob), ctnts in sents:
            filtered_labels = [decompose(label)[0]
                               if freqs.get(label, cutoff) < cutoff
                               else label for label in labels]
            filtered_sents.append(
                ((ids, words, tags, heads, filtered_labels, iob), ctnts))
        filtered.append((raw_text, filtered_sents))
    return filtered
