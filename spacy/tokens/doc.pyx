cimport cython
from libc.string cimport memcpy, memset
from libc.stdint cimport uint32_t

import numpy
import numpy.linalg
import struct
cimport numpy as np
import math

from ..lexeme cimport Lexeme
from ..lexeme cimport EMPTY_LEXEME
from ..typedefs cimport attr_t, flags_t
from ..attrs cimport attr_id_t
from ..attrs cimport ID, ORTH, NORM, LOWER, SHAPE, PREFIX, SUFFIX, LENGTH, CLUSTER
from ..attrs cimport POS, LEMMA, TAG, DEP, HEAD, SPACY, ENT_IOB, ENT_TYPE
from ..parts_of_speech import UNIV_POS_NAMES
from ..parts_of_speech cimport CONJ, PUNCT, NOUN
from ..parts_of_speech cimport univ_pos_t
from ..lexeme cimport Lexeme
from .spans cimport Span
from .token cimport Token
from ..serialize.bits cimport BitArray


DEF PADDING = 5


cdef int bounds_check(int i, int length, int padding) except -1:
    if (i + padding) < 0:
        raise IndexError
    if (i - padding) >= length:
        raise IndexError


cdef attr_t get_token_attr(const TokenC* token, attr_id_t feat_name) nogil:
    if feat_name == LEMMA:
        return token.lemma
    elif feat_name == POS:
        return token.pos
    elif feat_name == TAG:
        return token.tag
    elif feat_name == DEP:
        return token.dep
    elif feat_name == HEAD:
        return token.head
    elif feat_name == SPACY:
        return token.spacy
    elif feat_name == ENT_IOB:
        return token.ent_iob
    elif feat_name == ENT_TYPE:
        return token.ent_type
    else:
        return Lexeme.get_struct_attr(token.lex, feat_name)


cdef class Doc:
    """
    Container class for annotated text.  Constructed via English.__call__ or
    Tokenizer.__call__.
    """
    def __init__(self, Vocab vocab, orths_and_spaces=None):
        self.vocab = vocab
        size = 20
        self.mem = Pool()
        # Guarantee self.lex[i-x], for any i >= 0 and x < padding is in bounds
        # However, we need to remember the true starting places, so that we can
        # realloc.
        data_start = <TokenC*>self.mem.alloc(size + (PADDING*2), sizeof(TokenC))
        cdef int i
        for i in range(size + (PADDING*2)):
            data_start[i].lex = &EMPTY_LEXEME
            data_start[i].l_edge = i
            data_start[i].r_edge = i
        self.data = data_start + PADDING
        self.max_length = size
        self.length = 0
        self.is_tagged = False
        self.is_parsed = False
        self._py_tokens = []
        self._vector = None

    def __getitem__(self, object i):
        """Get a token.

        Returns:
            token (Token):
        """
        if isinstance(i, slice):
            if i.step is not None:
                raise ValueError("Stepped slices not supported in Span objects."
                                 "Try: list(doc)[start:stop:step] instead.")
            if i.start is None:
                i = slice(0, i.stop)
            if i.stop is None:
                i = slice(i.start, len(self))
            return Span(self, i.start, i.stop, label=0)

        if i < 0:
            i = self.length + i
        bounds_check(i, self.length, PADDING)
        if self._py_tokens[i] is not None:
            return self._py_tokens[i]
        else:
            return Token.cinit(self.vocab, &self.data[i], i, self)

    def __iter__(self):
        """Iterate over the tokens.

        Yields:
            token (Token):
        """
        cdef int i
        for i in range(self.length):
            if self._py_tokens[i] is not None:
                yield self._py_tokens[i]
            else:
                yield Token.cinit(self.vocab, &self.data[i], i, self)

    def __len__(self):
        return self.length

    def __unicode__(self):
        return u''.join([t.string for t in self])

    def __str__(self):
        return u''.join([t.string for t in self])

    def similarity(self, other):
        if self.vector_norm == 0 or other.vector_norm == 0:
            return 0.0
        return numpy.dot(self.vector, other.vector) / (self.vector_norm * other.vector_norm)

    property repvec:
        def __get__(self):
            return self.vector

    property vector:
        def __get__(self):
            if self._vector is None:
                self._vector = sum(t.vector for t in self) / len(self)
            return self._vector

        def __set__(self, value):
            self._vector = value

    property vector_norm:
        def __get__(self):
            cdef float value
            if self._vector_norm is None:
                self._vector_norm = 1e-20
                for value in self.vector:
                    self._vector_norm += value * value
                self._vector_norm = math.sqrt(self._vector_norm)
            return self._vector_norm
        
        def __set__(self, value):
            self._vector_norm = value 

    @property
    def string(self):
        return u''.join([t.string for t in self])

    @property
    def text_wth_ws(self):
        return u''.join([t.text_with_ws for t in self])

    @property
    def text(self):
        return u' '.join(t.text for t in self)

    property ents:
        def __get__(self):
            """Yields named-entity Span objects.
        
            Iterate over the span to get individual Token objects, or access the label:

            >>> from spacy.en import English
            >>> nlp = English()
            >>> tokens = nlp(u'Mr. Best flew to New York on Saturday morning.')
            >>> ents = list(tokens.ents)
            >>> ents[0].label, ents[0].label_, ''.join(t.orth_ for t in ents[0])
            (112504, u'PERSON', u'Best ') 
            """
            cdef int i
            cdef const TokenC* token
            cdef int start = -1
            cdef int label = 0
            output = []
            for i in range(self.length):
                token = &self.data[i]
                if token.ent_iob == 1:
                    assert start != -1
                elif token.ent_iob == 2 or token.ent_iob == 0:
                    if start != -1:
                        output.append(Span(self, start, i, label=label))
                    start = -1
                    label = 0
                elif token.ent_iob == 3:
                    if start != -1:
                        output.append(Span(self, start, i, label=label))
                    start = i
                    label = token.ent_type
            if start != -1:
                output.append(Span(self, start, self.length, label=label))
            return tuple(output)

        def __set__(self, ents):
            # TODO:
            # 1. Allow negative matches
            # 2. Ensure pre-set NERs are not over-written during statistical prediction
            # 3. Test basic data-driven ORTH gazetteer
            # 4. Test more nuanced date and currency regex
            cdef int i
            for i in range(self.length):
                self.data[i].ent_type = 0
                self.data[i].ent_iob = 0
            cdef attr_t ent_type
            cdef int start, end
            for ent_type, start, end in ents:
                if ent_type is None or ent_type < 0:
                    # Mark as O
                    for i in range(start, end):
                        self.data[i].ent_type = 0
                        self.data[i].ent_iob = 2
                else:
                    # Mark (inside) as I
                    for i in range(start, end):
                        self.data[i].ent_type = ent_type
                        self.data[i].ent_iob = 1
                    # Set start as B
                    self.data[start].ent_iob = 3

    @property
    def noun_chunks(self):
        """Yield spans for base noun phrases."""
        if not self.is_parsed:
            raise ValueError(
                "noun_chunks requires the dependency parse, which "
                "requires data to be installed. If you haven't done so, run: "
                "\npython -m spacy.en.download all\n"
                "to install the data")
 
        cdef const TokenC* word
        labels = ['nsubj', 'dobj', 'nsubjpass', 'pcomp', 'pobj', 'attr', 'conj']
        np_deps = [self.vocab.strings[label] for label in labels]
        np_label = self.vocab.strings['NP']
        for i in range(self.length):
            word = &self.data[i]
            if word.pos == NOUN and word.dep in np_deps:
                yield Span(self, word.l_edge, i+1, label=np_label)

    @property
    def sents(self):
        """
        Yield a list of sentence Span objects, calculated from the dependency parse.
        """
        if not self.is_parsed:
            raise ValueError(
                "sentence boundary detection requires the dependency parse, which "
                "requires data to be installed. If you haven't done so, run: "
                "\npython -m spacy.en.download all\n"
                "to install the data")
        cdef int i
        start = 0
        for i in range(1, self.length):
            if self.data[i].sent_start:
                yield Span(self, start, i)
                start = i
        yield Span(self, start, self.length)

    cdef int push_back(self, LexemeOrToken lex_or_tok, bint has_space) except -1:
        if self.length == self.max_length:
            self._realloc(self.length * 2)
        cdef TokenC* t = &self.data[self.length]
        if LexemeOrToken is const_TokenC_ptr:
            t[0] = lex_or_tok[0]
        else:
            t.lex = lex_or_tok
        if self.length == 0:
            t.idx = 0
        else:
            t.idx = (t-1).idx + (t-1).lex.length + (t-1).spacy
        t.l_edge = self.length
        t.r_edge = self.length
        assert t.lex.orth != 0
        t.spacy = has_space
        self.length += 1
        self._py_tokens.append(None)
        return t.idx + t.lex.length + t.spacy

    @cython.boundscheck(False)
    cpdef np.ndarray to_array(self, object py_attr_ids):
        """Given a list of M attribute IDs, export the tokens to a numpy ndarray
        of shape N*M, where N is the length of the sentence.

        Arguments:
            attr_ids (list[int]): A list of attribute ID ints.

        Returns:
            feat_array (numpy.ndarray[long, ndim=2]):
              A feature matrix, with one row per word, and one column per attribute
              indicated in the input attr_ids.
        """
        cdef int i, j
        cdef attr_id_t feature
        cdef np.ndarray[attr_t, ndim=2] output
        # Make an array from the attributes --- otherwise our inner loop is Python
        # dict iteration.
        cdef np.ndarray[attr_t, ndim=1] attr_ids = numpy.asarray(py_attr_ids, dtype=numpy.int32)
        output = numpy.ndarray(shape=(self.length, len(attr_ids)), dtype=numpy.int32)
        for i in range(self.length):
            for j, feature in enumerate(attr_ids):
                output[i, j] = get_token_attr(&self.data[i], feature)
        return output

    def count_by(self, attr_id_t attr_id, exclude=None, PreshCounter counts=None):
        """Produce a dict of {attribute (int): count (ints)} frequencies, keyed
        by the values of the given attribute ID.

        >>> from spacy.en import English, attrs
        >>> nlp = English()
        >>> tokens = nlp(u'apple apple orange banana')
        >>> tokens.count_by(attrs.ORTH)
        {12800L: 1, 11880L: 2, 7561L: 1}
        >>> tokens.to_array([attrs.ORTH])
        array([[11880],
               [11880],
               [ 7561],
               [12800]])
        """
        cdef int i
        cdef attr_t attr
        cdef size_t count
        
        if counts is None:
            counts = PreshCounter()
            output_dict = True
        else:
            output_dict = False
        # Take this check out of the loop, for a bit of extra speed
        if exclude is None:
            for i in range(self.length):
                counts.inc(get_token_attr(&self.data[i], attr_id), 1)
        else:
            for i in range(self.length):
                if not exclude(self[i]):
                    attr = get_token_attr(&self.data[i], attr_id)
                    counts.inc(attr, 1)
        if output_dict:
            return dict(counts)

    def _realloc(self, new_size):
        self.max_length = new_size
        n = new_size + (PADDING * 2)
        # What we're storing is a "padded" array. We've jumped forward PADDING
        # places, and are storing the pointer to that. This way, we can access
        # words out-of-bounds, and get out-of-bounds markers.
        # Now that we want to realloc, we need the address of the true start,
        # so we jump the pointer back PADDING places.
        cdef TokenC* data_start = self.data - PADDING
        data_start = <TokenC*>self.mem.realloc(data_start, n * sizeof(TokenC))
        self.data = data_start + PADDING
        cdef int i
        for i in range(self.length, self.max_length + PADDING):
            self.data[i].lex = &EMPTY_LEXEME

    cdef int set_parse(self, const TokenC* parsed) except -1:
        # TODO: This method is fairly misleading atm. It's used by Parser
        # to actually apply the parse calculated. Need to rethink this.

        # Probably we should use from_array?
        self.is_parsed = True
        for i in range(self.length):
            self.data[i] = parsed[i]
            assert self.data[i].l_edge <= i
            assert self.data[i].r_edge >= i

    def from_array(self, attrs, array):
        cdef int i, col
        cdef attr_id_t attr_id
        cdef TokenC* tokens = self.data
        cdef int length = len(array)
        cdef attr_t[:] values
        for col, attr_id in enumerate(attrs): 
            values = array[:, col]
            if attr_id == HEAD:
                for i in range(length):
                    tokens[i].head = values[i]
                    if values[i] >= 1:
                        tokens[i + values[i]].l_kids += 1
                    elif values[i] < 0:
                        tokens[i + values[i]].r_kids += 1
            elif attr_id == TAG:
                for i in range(length):
                    tokens[i].tag = values[i]
            elif attr_id == POS:
                for i in range(length):
                    tokens[i].pos = <univ_pos_t>values[i]
            elif attr_id == DEP:
                for i in range(length):
                    tokens[i].dep = values[i]
            elif attr_id == ENT_IOB:
                for i in range(length):
                    tokens[i].ent_iob = values[i]
            elif attr_id == ENT_TYPE:
                for i in range(length):
                    tokens[i].ent_type = values[i]
        set_children_from_heads(self.data, self.length)
        return self

    def to_bytes(self):
        byte_string = self.vocab.serializer.pack(self)
        cdef uint32_t length = len(byte_string)
        return struct.pack('I', length) + byte_string

    def from_bytes(self, data):
        self.vocab.serializer.unpack_into(data[4:], self)
        return self
    
    @staticmethod
    def read_bytes(file_):
        keep_reading = True
        while keep_reading:
            try:
                n_bytes_str = file_.read(4)
                if len(n_bytes_str) < 4:
                    break
                n_bytes = struct.unpack('I', n_bytes_str)[0]
                data = file_.read(n_bytes)
            except StopIteration:
                keep_reading = False
            yield n_bytes_str + data

    # This function is terrible --- need to fix this.
    def merge(self, int start_idx, int end_idx, unicode tag, unicode lemma,
              unicode ent_type):
        """Merge a multi-word expression into a single token.  Currently
        experimental; API is likely to change."""
        cdef int i
        cdef int start = -1
        cdef int end = -1
        for i in range(self.length):
            if self.data[i].idx == start_idx:
                start = i
            if (self.data[i].idx + self.data[i].lex.length) == end_idx:
                if start == -1:
                    return None
                end = i + 1
                break
        else:
            return None

        cdef Span span = self[start:end]
        # Get LexemeC for newly merged token
        new_orth = ''.join([t.string for t in span])
        if span[-1].whitespace_:
            new_orth = new_orth[:-1]
        cdef const LexemeC* lex = self.vocab.get(self.mem, new_orth)
        # House the new merged token where it starts
        cdef TokenC* token = &self.data[start]
        # Update fields
        token.lex = lex
        token.spacy = self.data[end-1].spacy
        # What to do about morphology??
        # TODO: token.morph = ???
        token.tag = self.vocab.strings[tag]
        token.lemma = self.vocab.strings[lemma]
        if ent_type == 'O':
            token.ent_iob = 2
            token.ent_type = 0
        else:
            token.ent_iob = 3
            token.ent_type = self.vocab.strings[ent_type]
        # Begin by setting all the head indices to absolute token positions
        # This is easier to work with for now than the offsets
        # Before thinking of something simpler, beware the case where a dependency
        # bridges over the entity. Here the alignment of the tokens changes.
        span_root = span.root.i
        token.dep = span.root.dep
        for i in range(self.length):
            self.data[i].head += i
        # Set the head of the merged token, and its dep relation, from the Span
        token.head = self.data[span_root].head
        # Adjust deps before shrinking tokens
        # Tokens which point into the merged token should now point to it
        # Subtract the offset from all tokens which point to >= end
        offset = (end - start) - 1
        for i in range(self.length):
            head_idx = self.data[i].head
            if start <= head_idx < end:
                self.data[i].head = start
            elif head_idx >= end:
                self.data[i].head -= offset
        # Now compress the token array
        for i in range(end, self.length):
            self.data[i - offset] = self.data[i]
        for i in range(self.length - offset, self.length):
            memset(&self.data[i], 0, sizeof(TokenC))
            self.data[i].lex = &EMPTY_LEXEME
        self.length -= offset
        for i in range(self.length):
            # ...And, set heads back to a relative position
            self.data[i].head -= i
        # Set the left/right children, left/right edges
        set_children_from_heads(self.data, self.length)
        # Clear the cached Python objects
        self._py_tokens = [None] * self.length
        # Return the merged Python object
        return self[start]


cdef int set_children_from_heads(TokenC* tokens, int length) except -1:
    cdef TokenC* head
    cdef TokenC* child
    cdef int i
    # Set left edges
    for i in range(length):
        child = &tokens[i]
        head = &tokens[i + child.head]
        if child < head and child.l_edge < head.l_edge:
            head.l_edge = child.l_edge
    # Set right edges --- same as above, but iterate in reverse
    for i in range(length-1, -1, -1):
        child = &tokens[i]
        head = &tokens[i + child.head]
        if child > head and child.r_edge > head.r_edge:
            head.r_edge = child.r_edge

