#ifdef __cplusplus
extern "C" {
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef __cplusplus
}
#endif

static int
not_here(s)
char *s;
{
    croak("%s not implemented on this architecture", s);
    return -1;
}

static double
constant(name, arg)
char *name;
int arg;
{
    errno = 0;
    switch (*name) {
    }
    errno = EINVAL;
    return 0;

not_there:
    errno = ENOENT;
    return 0;
}

#include <mm.h>

typedef struct {
	MM *mm;
	void *data;
	size_t size;
} mm_scalar;

mm_scalar *mm_make_scalar(MM *mm)
{
	mm_scalar *scalar;

	scalar = mm_malloc(mm, sizeof(mm_scalar));
	if (!scalar)
		return(0);

	scalar->mm = mm;
	scalar->data = 0;
	scalar->size = 0;

	return(scalar);
}

void mm_free_scalar(mm_scalar *scalar)
{
	if (scalar->data) {
		mm_free(scalar->mm, scalar->data);
		scalar->data = 0;
	}
	mm_free(scalar->mm, scalar);
}


SV *mm_scalar_get_core(mm_scalar *scalar)
{
	if (!scalar->data || !scalar->size)
		return(&sv_undef);

	return(newSVpvn(scalar->data, scalar->size));
}

SV *mm_scalar_get(mm_scalar *scalar)
{
	SV *sv = &sv_undef;
	if (mm_lock(scalar->mm, MM_LOCK_RD)) {
		sv = mm_scalar_get_core(scalar);
		mm_unlock(scalar->mm);
	}
	return(sv);
}

int mm_scalar_set(mm_scalar *scalar, SV *sv)
{
	void *data, *ptr, *oldptr;
	size_t size;

	data = SvPV(sv, size);

	ptr = mm_calloc(scalar->mm, 1, size + 1);
	if (!ptr)
		return(0);

	if (!mm_lock(scalar->mm, MM_LOCK_RW))
		return(0);

	memcpy(ptr, data, size);
	oldptr = scalar->data;
	scalar->data = ptr;
	scalar->size = size;

	mm_unlock(scalar->mm);

	mm_free(scalar->mm, oldptr);

	return(1);
}

struct mm_btree_elt;
typedef struct mm_btree_elt mm_btree_elt;

typedef struct {
	MM *mm;
	int (*func)(const void *, const void *);
	int nelts;
	struct mm_btree_elt *root;
} mm_btree;

struct mm_btree_elt {
	struct mm_btree_elt *parent;
	struct mm_btree_elt *prev;
	void *curr;
	struct mm_btree_elt *next;
};

mm_btree *mm_make_btree(MM *mm, int (*func)(const void *, const void *))
{
	mm_btree *btree;

	btree = mm_calloc(mm, 1, sizeof(mm_btree));
	if (!btree)
		return(0);

	btree->mm = mm;
	btree->func = func;

	return(btree);
}

void mm_free_btree(mm_btree *btree)
{
	mm_free(btree->mm, btree);
}

mm_btree_elt *mm_btree_get_core(mm_btree *btree, mm_btree_elt *elt, void *key)
{
	mm_btree_elt *res = 0;

	if (elt) {
		int rc;
		rc = btree->func(key, elt->curr);
		if (rc == 0)
			res = elt;
		else if (rc < 0)
			res = mm_btree_get_core(btree, elt->prev, key);
		else
			res = mm_btree_get_core(btree, elt->next, key);
	}

	return(res);
}

void *mm_btree_get(mm_btree *btree, void *key)
{
	mm_btree_elt *elt;
	elt = mm_btree_get_core(btree, btree->root, key);
	return((elt) ? elt->curr : 0);
}

void mm_btree_insert_core(mm_btree *btree, mm_btree_elt *elt, mm_btree_elt *key)
{
	int rc;
	rc = btree->func(key->curr, elt->curr);
	if (rc < 0) {
		if (elt->prev) {
			mm_btree_insert_core(btree, elt->prev, key);
		} else {
			key->parent = elt;
			elt->prev = key;
			btree->nelts++;
		}
	} else if (rc > 0) {
		if (elt->next) {
			mm_btree_insert_core(btree, elt->next, key);
		} else {
			key->parent = elt;
			elt->next = key;
			btree->nelts++;
		}
	}
}

void mm_btree_insert(mm_btree *btree, mm_btree_elt *key)
{
	if (btree->root) {
		mm_btree_insert_core(btree, btree->root, key);
	} else {
		key->parent = 0;
		btree->root = key;
		btree->nelts++;
	}
}

void mm_btree_remove(mm_btree *btree, mm_btree_elt *key)
{
	if (key->parent) {
		if (key->parent->prev == key) {
			key->parent->prev = 0;
		} else if (key->parent->next == key) {
			key->parent->next = 0;
		}
	} else {
		btree->root = 0;
	}
	if (key->prev)
		mm_btree_insert(btree, key->prev);
	if (key->next)
		mm_btree_insert(btree, key->next);
	btree->nelts--;
}

typedef struct {
	char *key;
	mm_scalar *val;
} table_entry;

int btree_table_compare(const void *pa, const void *pb)
{
	table_entry *a, *b;
	a = (table_entry *) pa;
	b = (table_entry *) pb;
	return(strcmp(a->key, b->key));
}

mm_btree *mm_make_btree_table(MM *mm)
{
	return(mm_make_btree(mm, btree_table_compare));
}

void mm_free_btree_table_elt(mm_btree *btree, mm_btree_elt *elt)
{
	table_entry *telt;
	telt = elt->curr;
	if (telt) {
		if (telt->key) mm_free(btree->mm, telt->key);
		if (telt->val) mm_free_scalar(telt->val);
		mm_free(btree->mm, telt);
	}
	mm_free(btree->mm, elt);
}

void mm_clear_btree_table_core(mm_btree *btree, mm_btree_elt *elt)
{
	if (elt->prev)
		mm_clear_btree_table_core(btree, elt->prev);
	if (elt->next)
		mm_clear_btree_table_core(btree, elt->next);
	mm_free_btree_table_elt(btree, elt);
}

void mm_clear_btree_table(mm_btree *btree)
{
	mm_btree_elt *root = 0;

	if (mm_lock(btree->mm, MM_LOCK_RW)) {
		root = btree->root;
		btree->root = 0;
		mm_unlock(btree->mm);
	}

	if (root)
		mm_clear_btree_table_core(btree, root);
}

void mm_free_btree_table(mm_btree *btree)
{
	mm_clear_btree_table(btree);
	mm_free_btree(btree);
}

SV *mm_btree_table_get_core(mm_btree *btree, char *key)
{
	table_entry elt, *match;
	elt.key = key;
	elt.val = 0;
	match = mm_btree_get(btree, &elt);
	return((match && match->val) ? mm_scalar_get_core(match->val) : &sv_undef);
}

SV *mm_btree_table_get(mm_btree *btree, char *key)
{
	SV *ret = &sv_undef;
	if (mm_lock(btree->mm, MM_LOCK_RD)) {
		ret = mm_btree_table_get_core(btree, key);
		mm_unlock(btree->mm);
	}
	return(ret);
}

int mm_btree_table_insert(mm_btree *btree, char *key, SV *val)
{
	mm_scalar *scalar;
	table_entry *telt;
	mm_btree_elt *belt, *old = 0;
	int rc;

	scalar = mm_make_scalar(btree->mm);
	if (!scalar)
		return(0);

	rc = mm_scalar_set(scalar, val);
	if (!rc)
		return(0);

	telt = mm_malloc(btree->mm, sizeof(table_entry));
	if (!telt)
		return(0);
	telt->key = mm_strdup(btree->mm, key);
	if (!telt->key)
		return(0);
	telt->val = scalar;

	belt = mm_calloc(btree->mm, 1, sizeof(mm_btree_elt));
	if (!belt)
		return(0);
	belt->curr = telt;

	if (mm_lock(btree->mm, MM_LOCK_RW)) {
		old = mm_btree_get_core(btree, btree->root, telt);
		if (old)
			mm_btree_remove(btree, old);
		mm_btree_insert(btree, belt);
		mm_unlock(btree->mm);
	}

	if (old)
		mm_free_btree_table_elt(btree, old);

	return(1);
}

SV *mm_btree_table_delete(mm_btree *btree, char *key)
{
	SV *ret = &sv_undef;
	mm_btree_elt *old = 0;
	if (mm_lock(btree->mm, MM_LOCK_RW)) {
		table_entry elt;
		elt.key = key;
		elt.val = 0;
		old = mm_btree_get_core(btree, btree->root, &elt);
		if (old)
			mm_btree_remove(btree, old);
		mm_unlock(btree->mm);
	}
	if (old) {
		table_entry *elt;
		elt = old->curr;
		if (elt && elt->val)
			ret = mm_scalar_get_core(elt->val);
		mm_free_btree_table_elt(btree, old);
	}
	return(ret);
}

SV *
mm_btree_table_exists(mm_btree *btree, char *key)
{
	SV *ret = &sv_undef;
	if (mm_lock(btree->mm, MM_LOCK_RD)) {
		table_entry elt;
		elt.key = key;
		elt.val = 0;
		ret = (mm_btree_get_core(btree, btree->root, &elt)) ? &sv_yes : &sv_no;
		mm_unlock(btree->mm);
	}
	return(ret);
}

SV *mm_btree_table_first_key_core(mm_btree *btree, mm_btree_elt *elt)
{
	table_entry *telt;
	if (elt->prev)
		return(mm_btree_table_first_key_core(btree, elt->prev));
	telt = elt->curr;
	return((telt && telt->key) ? newSVpv(telt->key, 0) : &sv_undef);
}

SV *mm_btree_table_first_key(mm_btree *btree)
{
	SV *ret = &sv_undef;
	if (mm_lock(btree->mm, MM_LOCK_RD)) {
		if (btree->root)
			ret = mm_btree_table_first_key_core(btree, btree->root);
		mm_unlock(btree->mm);
	}
	return(ret);
}

SV *mm_btree_table_next_key_core(mm_btree *btree, mm_btree_elt *elt)
{
	if (elt->parent && elt->parent->prev == elt) {
		table_entry *telt;
		telt = elt->parent->curr;
		return((telt && telt->key) ? newSVpv(telt->key, 0) : &sv_undef);
	} else if (elt->parent && elt->parent->next == elt) {
		return(mm_btree_table_next_key_core(btree, elt->parent));
	} else {
		return(&sv_undef);
	}
}

SV *mm_btree_table_next_key(mm_btree *btree, char *key)
{
	SV *ret = &sv_undef;
	if (mm_lock(btree->mm, MM_LOCK_RD)) {
		mm_btree_elt *elt;
		table_entry telt;
		telt.key = key;
		telt.val = 0;
		elt = mm_btree_get_core(btree, btree->root, &telt);
		if (elt) {
			if (elt->next)
				ret = mm_btree_table_first_key_core(btree, elt->next);
			else
				ret = mm_btree_table_next_key_core(btree, elt);
		}
		mm_unlock(btree->mm);
	}
	return(ret);
}



MODULE = IPC::MM		PACKAGE = IPC::MM		


double
constant(name,arg)
	char *		name
	int		arg


MM *
mm_create(size, file)
	size_t size
	char *file

int
mm_permission(mm, mode, owner, group)
	MM *mm
	int mode
	int owner
	int group

void
mm_destroy(mm)
	MM *mm

mm_scalar *
mm_make_scalar(mm)
	MM *mm

void
mm_free_scalar(scalar)
	mm_scalar *scalar

SV *
mm_scalar_get(scalar)
	mm_scalar *scalar

int
mm_scalar_set(scalar, sv)
	mm_scalar *scalar
	SV *sv

mm_btree *
mm_make_btree_table(mm)
	MM *mm

void
mm_clear_btree_table(btree)
	mm_btree *btree

void
mm_free_btree_table(btree)
	mm_btree *btree

SV *
mm_btree_table_get(btree, key)
	mm_btree *btree
	char *key

int
mm_btree_table_insert(btree, key, val)
	mm_btree *btree
	char *key
	SV *val

SV *
mm_btree_table_delete(btree, key)
	mm_btree *btree
	char *key

SV *
mm_btree_table_exists(btree, key)
	mm_btree *btree
	char *key

SV *
mm_btree_table_first_key(btree)
	mm_btree *btree

SV *
mm_btree_table_next_key(btree, key)
	mm_btree *btree
	char *key

size_t
mm_maxsize()

size_t
mm_available(mm)
	MM *mm

char *
mm_error()

void
mm_display_info(mm)
	MM *mm


