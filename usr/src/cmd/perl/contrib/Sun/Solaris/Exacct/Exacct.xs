/*
 * Copyright (c) 2002, Oracle and/or its affiliates. All rights reserved.
 *
 * Exacct.xs contains XS code for creating various exacct-related constants,
 * and for providing wrappers around exacct error handling and
 * accounting-related system calls.  It also contains commonly-used utility
 * code shared by its sub-modules.
 */

#include <string.h>
#include "exacct_common.xh"

/*
 * Pull in the file generated by extract_defines.  This contains a table
 * of numeric constants and their string equivalents which have been extracted
 * from the various exacct header files by the extract_defines script.
 */
#include "ExacctDefs.xi"

/*
 * Object stash pointers - caching these speeds up the creation and
 * typechecking of perl objects by removing the need to do a hash lookup.
 * The peculiar variable names are so that typemaps can generate the correct
 * package name using the typemap '$Package' variable as the root of the name.
 */
HV *Sun_Solaris_Exacct_Catalog_stash;
HV *Sun_Solaris_Exacct_File_stash;
HV *Sun_Solaris_Exacct_Object_Item_stash;
HV *Sun_Solaris_Exacct_Object_Group_stash;
HV *Sun_Solaris_Exacct_Object__Array_stash;

/*
 * Pointer to part of the hash tree built by define_catalog_constants in
 * Catalog.xs.  This is used by catalog_id_str() when mapping from a catalog
 * to an id string.
 */
HV *IdValueHash = NULL;

/*
 * Last buffer size used for packing and unpacking exacct objects.
 */
static int last_bufsz = 0;

/*
 * Common utility code.  This is placed here instead of in the sub-modules to
 * reduce the number of cross-module linker dependencies that are required,
 * although most of the code more properly belongs in the sub-modules.
 */

/*
 * This function populates the various stash pointers used by the ::Exacct
 * module.  It is called from each of the module BOOT sections to ensure the
 * stash pointers are initialised on startup.
 */
void
init_stashes(void)
{
	if (Sun_Solaris_Exacct_Catalog_stash == NULL) {
		Sun_Solaris_Exacct_Catalog_stash =
		    gv_stashpv(PKGBASE "::Catalog", TRUE);
		Sun_Solaris_Exacct_File_stash =
		    gv_stashpv(PKGBASE "::File", TRUE);
		Sun_Solaris_Exacct_Object_Item_stash =
		    gv_stashpv(PKGBASE "::Object::Item", TRUE);
		Sun_Solaris_Exacct_Object_Group_stash =
		    gv_stashpv(PKGBASE "::Object::Group", TRUE);
		Sun_Solaris_Exacct_Object__Array_stash =
		    gv_stashpv(PKGBASE "::Object::_Array", TRUE);
	}
}

/*
 * This function populates the @_Constants array in the specified package
 * based on the values extracted from the exacct header files by the
 * extract_defines script and written to the .xi file which is included above.
 * It also creates a const sub for each constant that returns the associcated
 * value.  It should be called from the BOOT sections of modules that export
 * constants.
 */
#define	CONST_NAME "::_Constants"
void
define_constants(const char *pkg, constval_t *cvp)
{
	HV		*stash;
	char		*name;
	AV		*constants;

	/* Create the new perl @_Constants variable. */
	stash = gv_stashpv(pkg, TRUE);
	name = New(0, name, strlen(pkg) + sizeof (CONST_NAME), char);
	PERL_ASSERT(name != NULL);
	strcpy(name, pkg);
	strcat(name, CONST_NAME);
	constants = perl_get_av(name, TRUE);
	Safefree(name);

	/* Populate @_Constants from the contents of the generated array. */
	for (; cvp->name != NULL; cvp++) {
		newCONSTSUB(stash, (char *)cvp->name, newSVuv(cvp->value));
		av_push(constants, newSVpvn((char *)cvp->name, cvp->len));
	}
}
#undef CONST_NAME

/*
 * Return a new Catalog object - only accepts an integer catalog value.
 * Use this purely for speed when creating Catalog objects from other XS code.
 * All other Catalog object creation should be done with the perl new() method.
 */
SV*
new_catalog(uint32_t cat)
{
	SV *iv, *ref;

	iv = newSVuv(cat);
	ref = newRV_noinc(iv);
	sv_bless(ref, Sun_Solaris_Exacct_Catalog_stash);
	SvREADONLY_on(iv);
	return (ref);
}

/*
 * Return the integer catalog value from the passed Catalog or IV.
 * Calls croak() if the SV is not of the correct type.
 */
ea_catalog_t
catalog_value(SV *catalog)
{
	SV	*sv;

	/* If a reference, dereference and check it is a Catalog. */
	if (SvROK(catalog)) {
		sv = SvRV(catalog);
		if (SvIOK(sv) &&
		    SvSTASH(sv) == Sun_Solaris_Exacct_Catalog_stash) {
			return (SvIV(sv));
		} else {
			croak("Parameter is not a Catalog or integer");
		}

	/* For a plain IV, just return the value. */
	} else if (SvIOK(catalog)) {
		return (SvIV(catalog));

	/* Anything else is an error */
	} else {
		croak("Parameter is not a Catalog or integer");
	}
}

/*
 * Return the string value of the id subfield of an ea_catalog_t.
 */
char *
catalog_id_str(ea_catalog_t catalog)
{
	static ea_catalog_t	cat_val = ~0U;
	static HV		*cat_hash = NULL;
	ea_catalog_t		cat;
	ea_catalog_t		id;
	char			key[12];    /* Room for dec(2^32) digits. */
	SV			**svp;

	cat = catalog & EXC_CATALOG_MASK;
	id = catalog & EXD_DATA_MASK;

	/* Fetch the correct id subhash if the catalog has changed. */
	if (cat_val != cat) {
		snprintf(key, sizeof (key), "%d", cat);
		PERL_ASSERT(IdValueHash != NULL);
		svp = hv_fetch(IdValueHash, key, strlen(key), FALSE);
		if (svp == NULL) {
			cat_val = ~0U;
			cat_hash = NULL;
		} else {
			HV *hv;

			cat_val = cat;
			hv = (HV *)SvRV(*svp);
			PERL_ASSERT(hv != NULL);
			svp = hv_fetch(hv, "value", 5, FALSE);
			PERL_ASSERT(svp != NULL);
			cat_hash = (HV *)SvRV(*svp);
			PERL_ASSERT(cat_hash != NULL);
		}
	}

	/* If we couldn't find the hash, it is a catalog we don't know about. */
	if (cat_hash == NULL) {
		return ("UNKNOWN_ID");
	}

	/* Fetch the value from the selected catalog and return it. */
	snprintf(key, sizeof (key), "%d", id);
	svp = hv_fetch(cat_hash, key, strlen(key), TRUE);
	if (svp == NULL) {
		return ("UNKNOWN_ID");
	}
	return (SvPVX(*svp));
}

/*
 * Create a new ::Object by wrapping an ea_object_t in a perl SV.  This is used
 * to wrap exacct records that have been read from a file, or packed records
 * that have been inflated.
 */
SV *
new_xs_ea_object(ea_object_t *ea_obj)
{
	xs_ea_object_t	*xs_obj;
	SV		*sv_obj;

	/* Allocate space - use perl allocator. */
	New(0, xs_obj, 1, xs_ea_object_t);
	PERL_ASSERT(xs_obj != NULL);
	xs_obj->ea_obj = ea_obj;
	xs_obj->perl_obj = NULL;
	sv_obj = NEWSV(0, 0);
	PERL_ASSERT(sv_obj != NULL);

	/*
	 * Initialise according to the type of the passed exacct object,
	 * and bless the perl object into the appropriate class.
	 */
	if (ea_obj->eo_type == EO_ITEM) {
		if ((ea_obj->eo_catalog & EXT_TYPE_MASK) == EXT_EXACCT_OBJECT) {
			INIT_EMBED_ITEM_FLAGS(xs_obj);
		} else {
			INIT_PLAIN_ITEM_FLAGS(xs_obj);
		}
		sv_setiv(newSVrv(sv_obj, NULL), PTR2IV(xs_obj));
		sv_bless(sv_obj, Sun_Solaris_Exacct_Object_Item_stash);
	} else {
		INIT_GROUP_FLAGS(xs_obj);
		sv_setiv(newSVrv(sv_obj, NULL), PTR2IV(xs_obj));
		sv_bless(sv_obj, Sun_Solaris_Exacct_Object_Group_stash);
	}

	/*
	 * We are passing back a pointer masquerading as a perl IV,
	 * so make sure it can't be modified.
	 */
	SvREADONLY_on(SvRV(sv_obj));
	return (sv_obj);
}

/*
 * Convert the perl form of an ::Object into the corresponding exacct form.
 * This is used prior to writing an ::Object to a file, or passing it to
 * putacct.  This is only required for embedded items and groups - for normal
 * items it is a no-op.
 */
ea_object_t *
deflate_xs_ea_object(SV *sv)
{
	xs_ea_object_t	*xs_obj;
	ea_object_t	*ea_obj;

	/* Get the source xs_ea_object_t. */
	PERL_ASSERT(sv != NULL);
	sv = SvRV(sv);
	PERL_ASSERT(sv != NULL);
	xs_obj = INT2PTR(xs_ea_object_t *, SvIV(sv));
	PERL_ASSERT(xs_obj != NULL);
	ea_obj = xs_obj->ea_obj;
	PERL_ASSERT(ea_obj != NULL);

	/* Break any list this object is a part of. */
	ea_obj->eo_next = NULL;

	/* Deal with Items containing embedded Objects. */
	if (IS_EMBED_ITEM(xs_obj)) {
		xs_ea_object_t	*child_xs_obj;
		SV		*perl_obj;
		size_t		bufsz;

		/* Get the underlying perl object an deflate that in turn. */
		perl_obj = xs_obj->perl_obj;
		PERL_ASSERT(perl_obj != NULL);
		deflate_xs_ea_object(perl_obj);
		perl_obj = SvRV(perl_obj);
		PERL_ASSERT(perl_obj != NULL);
		child_xs_obj = INT2PTR(xs_ea_object_t *, SvIV(perl_obj));
		PERL_ASSERT(child_xs_obj->ea_obj != NULL);

		/* Free any existing object contents. */
		if (ea_obj->eo_item.ei_object != NULL) {
			ea_free(ea_obj->eo_item.ei_object,
			    ea_obj->eo_item.ei_size);
			ea_obj->eo_item.ei_object = NULL;
			ea_obj->eo_item.ei_size = 0;
		}

		/*  Pack the object. */
		while (1) {
			/* Use the last buffer size as a best guess. */
			if (last_bufsz != 0) {
				ea_obj->eo_item.ei_object =
				    ea_alloc(last_bufsz);
				PERL_ASSERT(ea_obj->eo_item.ei_object != NULL);
			} else {
				ea_obj->eo_item.ei_object = NULL;
			}

			/*
			 * Pack the object.  If the buffer is too small,
			 * we will go around again with the correct size.
			 * If unsucessful, we will bail.
			 */
			if ((bufsz = ea_pack_object(child_xs_obj->ea_obj,
			    ea_obj->eo_item.ei_object, last_bufsz)) == -1) {
				ea_free(ea_obj->eo_item.ei_object, last_bufsz);
				ea_obj->eo_item.ei_object = NULL;
				return (NULL);
			} else if (bufsz > last_bufsz) {
				ea_free(ea_obj->eo_item.ei_object, last_bufsz);
				last_bufsz = bufsz;
				continue;
			} else {
				ea_obj->eo_item.ei_size = bufsz;
				break;
			}
		}

	/* Deal with Groups. */
	} else if (IS_GROUP(xs_obj)) {
		MAGIC		*mg;
		AV		*av;
		int		len, i;
		xs_ea_object_t	*ary_xs;
		ea_object_t	*ary_ea, *prev_ea;

		/* Find the AV underlying the tie. */
		mg = mg_find(SvRV(xs_obj->perl_obj), 'P');
		PERL_ASSERT(mg != NULL);
		av = (AV*)SvRV(mg->mg_obj);
		PERL_ASSERT(av != NULL);

		/*
		 * Step along the AV, deflating each object and linking it into
		 * the exacct group item list.
		 */
		prev_ea = ary_ea = NULL;
		len = av_len(av) + 1;
		ea_obj->eo_group.eg_nobjs = 0;
		ea_obj->eo_group.eg_objs = NULL;
		for (i = 0; i < len; i++) {
			/*
			 * Get the source xs_ea_object_t.  If the current slot
			 * in the array is empty, skip it.
			 */
			SV	**ary_svp;
			if ((ary_svp = av_fetch(av, i, FALSE)) == NULL) {
				continue;
			}
			PERL_ASSERT(*ary_svp != NULL);

			/* Deflate it. */
			ary_ea = deflate_xs_ea_object(*ary_svp);
			PERL_ASSERT(ary_ea != NULL);

			/* Link into the list. */
			ary_ea->eo_next = NULL;
			if (ea_obj->eo_group.eg_objs == NULL) {
				ea_obj->eo_group.eg_objs = ary_ea;
			}
			ea_obj->eo_group.eg_nobjs++;
			if (prev_ea != NULL) {
				prev_ea->eo_next = ary_ea;
			}
			prev_ea = ary_ea;
		}
	}
	return (ea_obj);
}

/*
 * Private Sun::Solaris::Exacct utility code.
 */

/*
 * Return a string representation of an ea_error.
 */
static const char *
error_str(int eno)
{
	switch (eno) {
	case EXR_OK:
		return ("no error");
	case EXR_SYSCALL_FAIL:
		return ("system call failed");
	case EXR_CORRUPT_FILE:
		return ("corrupt file");
	case EXR_EOF:
		return ("end of file");
	case EXR_NO_CREATOR:
		return ("no creator");
	case EXR_INVALID_BUF:
		return ("invalid buffer");
	case EXR_NOTSUPP:
		return ("not supported");
	case EXR_UNKN_VERSION:
		return ("unknown version");
	case EXR_INVALID_OBJ:
		return ("invalid object");
	default:
		return ("unknown error");
	}
}

/*
 * The XS code exported to perl is below here.  Note that the XS preprocessor
 * has its own commenting syntax, so all comments from this point on are in
 * that form.
 */

MODULE = Sun::Solaris::Exacct PACKAGE = Sun::Solaris::Exacct
PROTOTYPES: ENABLE

 #
 # Define the stash pointers if required and create and populate @_Constants.
 #
BOOT:
	init_stashes();
	define_constants(PKGBASE, constants);

 #
 # Return the last exacct error as a dual-typed SV.  In a numeric context the
 # SV will evaluate to the value of an EXR_* constant, in string context to a
 # error message.
 #
SV*
ea_error()
PREINIT:
	int		eno;
	const char	*msg;
CODE:
	eno = ea_error();
	msg = error_str(eno);
	RETVAL = newSViv(eno);
	sv_setpv(RETVAL, (char*) msg);
	SvIOK_on(RETVAL);
OUTPUT:
	RETVAL

 #
 # Return a string describing the last error to be encountered.  If the value
 # returned by ea_error is EXR_SYSCALL_FAIL, a string describing the value of
 # errno will be returned.  For all other values returned by ea_error() a string
 # describing the exacct error will be returned.
 #
char*
ea_error_str()
PREINIT:
	int	eno;
CODE:
	eno = ea_error();
	if (eno == EXR_SYSCALL_FAIL) {
		RETVAL = strerror(errno);
		if (RETVAL == NULL) {
			RETVAL = "unknown system error";
		}
	} else {
		RETVAL = (char*) error_str(eno);
	}
OUTPUT:
	RETVAL

 #
 # Return an accounting record for the specified task or process. idtype is
 # either P_TASKID or P_PID and id is a process or task id.
 #
SV*
getacct(idtype, id)
	idtype_t	idtype;
	id_t		id;
PREINIT:
	int		bufsz;
	char		*buf;
	ea_object_t	*ea_obj;
CODE:
	/* Get the required accounting buffer. */
	while (1) {
		/* Use the last buffer size as a best guess. */
		if (last_bufsz != 0) {
			buf = ea_alloc(last_bufsz);
			PERL_ASSERT(buf != NULL);
		} else {
			buf = NULL;
		}

		/*
		 * get the accounting record.  If the buffer is too small,
		 * we will go around again with the correct size.
		 * If unsucessful, we will bail.
		 */
		if ((bufsz = getacct(idtype, id, buf, last_bufsz)) == -1) {
			if (last_bufsz != 0) {
				ea_free(buf, last_bufsz);
			}
			XSRETURN_UNDEF;
		} else if (bufsz > last_bufsz) {
			ea_free(buf, last_bufsz);
			last_bufsz = bufsz;
			continue;
		} else {
			break;
		}
	}

	/* Unpack the buffer. */
	if (ea_unpack_object(&ea_obj, EUP_ALLOC, buf, bufsz) == -1) {
		ea_free(buf, last_bufsz);
		XSRETURN_UNDEF;
	}
	ea_free(buf, last_bufsz);
	RETVAL = new_xs_ea_object(ea_obj);
OUTPUT:
	RETVAL

 #
 # Write an accounting record into the system accounting file. idtype is
 # either P_TASKID or P_PID and id is a process or task id.  value may be either
 # an ::Exacct::Object, in which case it will be packed and inserted in the
 # file, or a SV which will be converted to a string and inserted into the file.
 #
SV*
putacct(idtype, id, value)
	idtype_t	idtype;
	id_t		id;
	SV		*value;
PREINIT:
	HV		*stash;
	unsigned int	bufsz;
	int		flags, ret;
	char		*buf;
CODE:
	/* If it is an ::Object::Item or ::Object::Group, pack it. */
	stash = SvROK(value) ? SvSTASH(SvRV(value)) : NULL;
	if (stash == Sun_Solaris_Exacct_Object_Item_stash ||
	    stash == Sun_Solaris_Exacct_Object_Group_stash) {
		ea_object_t	*obj;

		/* Deflate the object. */
		if ((obj = deflate_xs_ea_object(value)) == NULL) {
			XSRETURN_NO;
		}

		/*  Pack the object. */
		while (1) {
			/* Use the last buffer size as a best guess. */
			if (last_bufsz != 0) {
				buf = ea_alloc(last_bufsz);
				PERL_ASSERT(buf != NULL);
			} else {
				buf = NULL;
			}

			/*
			 * Pack the object.  If the buffer is too small, we
			 * will go around again with the correct size.
			 * If unsucessful, we will bail.
			 */
			if ((bufsz = ea_pack_object(obj, buf, last_bufsz))
			    == -1) {
				if (last_bufsz != 0) {
					ea_free(buf, last_bufsz);
				}
				XSRETURN_NO;
			} else if (bufsz > last_bufsz) {
				ea_free(buf, last_bufsz);
				last_bufsz = bufsz;
				continue;
			} else {
				break;
			}
		}
		flags = EP_EXACCT_OBJECT;

	/* Otherwise treat it as normal SV - convert to a string. */
	} else {
		buf = SvPV(value, bufsz);
		flags = EP_RAW;
	}

	/* Call putacct to write the buffer */
	RETVAL = putacct(idtype, id, buf, bufsz, flags) == 0
	    ? &PL_sv_yes : &PL_sv_no;

	/*  Clean up if we allocated a buffer. */
	if (flags == EP_EXACCT_OBJECT) {
		ea_free(buf, last_bufsz);
	}
OUTPUT:
	RETVAL

 #
 # Write an accounting record for the specified task or process.  idtype is
 # either P_TASKID or P_PID, id is a process or task id and flags is either
 # EW_PARTIAL or EW_INTERVAL.
 #
int
wracct(idtype, id, flags)
	idtype_t	idtype;
	id_t		id;
	int		flags;