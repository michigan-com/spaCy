from libcpp.vector cimport vector

from preshed.maps cimport PreshMap
from cymem.cymem cimport Pool
from murmurhash.mrmr cimport hash64

from .structs cimport LexemeC, TokenC
from .typedefs cimport utf8_t, attr_t, hash_t
from .strings cimport StringStore
from .morphology cimport Morphology


cdef LexemeC EMPTY_LEXEME


cdef union LexemesOrTokens:
    const LexemeC* const* lexemes
    const TokenC* tokens


cdef struct _Cached:
    LexemesOrTokens data
    bint is_lex
    int length


cdef class Vocab:
    cpdef public lexeme_props_getter
    cdef Pool mem
    cpdef readonly StringStore strings
    cpdef readonly Morphology morphology
    cdef readonly int length
    cdef public object _serializer
    cdef public object data_dir
    cdef public object get_lex_attr
    cdef public object pos_tags
    cdef public object serializer_freqs

    cdef const LexemeC* get(self, Pool mem, unicode string) except NULL
    cdef const LexemeC* get_by_orth(self, Pool mem, attr_t orth) except NULL
    cdef const TokenC* make_fused_token(self, substrings) except NULL
    
    cdef const LexemeC* _new_lexeme(self, Pool mem, unicode string) except NULL
    cdef int _add_lex_to_vocab(self, hash_t key, const LexemeC* lex) except -1
    cdef const LexemeC* _new_lexeme(self, Pool mem, unicode string) except NULL

    cdef PreshMap _by_hash
    cdef PreshMap _by_orth
    cdef readonly int vectors_length
