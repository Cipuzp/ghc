%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[HsTypes]{Abstract syntax: user-defined types}

If compiled without \tr{#define COMPILING_GHC}, you get
(part of) a Haskell-abstract-syntax library.  With it,
you get part of GHC.

\begin{code}
#include "HsVersions.h"

module HsTypes (
	HsType(..), HsTyVar(..),
	SYN_IE(Context), SYN_IE(ClassAssertion)

	, mkHsForAllTy
	, getTyVarName, replaceTyVarName
	, pprParendHsType
	, pprContext
	, cmpHsType, cmpContext
    ) where

IMP_Ubiq()

import Outputable	( interppSP, ifnotPprForUser )
import Kind		( Kind {- instance Outputable -} )
import Name		( nameOccName )
import Pretty
import PprStyle		( PprStyle(..) )
import Util		( thenCmp, cmpList, isIn, panic# )
\end{code}

This is the syntax for types as seen in type signatures.

\begin{code}
type Context name = [ClassAssertion name]

type ClassAssertion name = (name, HsType name)
	-- The type is usually a type variable, but it
	-- doesn't have to be when reading interface files

data HsType name
  = HsPreForAllTy	(Context name)
			(HsType name)

	-- The renamer turns HsPreForAllTys into HsForAllTys when they
	-- occur in signatures, to make the binding of variables
	-- explicit.  This distinction is made visible for
	-- non-COMPILING_GHC code, because you probably want to do the
	-- same thing.

  | HsForAllTy		[HsTyVar name]
			(Context name)
			(HsType name)

  | MonoTyVar		name		-- Type variable

  | MonoTyApp		name		-- Type constructor or variable
			[HsType name]

    -- We *could* have a "MonoTyCon name" equiv to "MonoTyApp name []"
    -- (for efficiency, what?)  WDP 96/02/18

  | MonoFunTy		(HsType name) -- function type
			(HsType name)

  | MonoListTy		name		-- The list TyCon name
			(HsType name)	-- Element type

  | MonoTupleTy		name		-- The tuple TyCon name
			[HsType name]	-- Element types (length gives arity)

  -- these next two are only used in unfoldings in interfaces
  | MonoDictTy		name	-- Class
			(HsType name)

mkHsForAllTy []  []   ty = ty
mkHsForAllTy tvs ctxt ty = HsForAllTy tvs ctxt ty

data HsTyVar name
  = UserTyVar name
  | IfaceTyVar name Kind
	-- *** NOTA BENE *** A "monotype" in a pragma can have
	-- for-alls in it, (mostly to do with dictionaries).  These
	-- must be explicitly Kinded.

getTyVarName (UserTyVar n)    = n
getTyVarName (IfaceTyVar n _) = n

replaceTyVarName :: HsTyVar name1 -> name2 -> HsTyVar name2
replaceTyVarName (UserTyVar n)    n' = UserTyVar n'
replaceTyVarName (IfaceTyVar n k) n' = IfaceTyVar n' k
\end{code}


%************************************************************************
%*									*
\subsection{Pretty printing}
%*									*
%************************************************************************

\begin{code}

instance (Outputable name) => Outputable (HsType name) where
    ppr = pprHsType

instance (Outputable name) => Outputable (HsTyVar name) where
    ppr sty (UserTyVar name) = ppr_hs_tyvar sty name
    ppr sty (IfaceTyVar name kind) = ppCat [ppr_hs_tyvar sty name, ppStr "::", ppr sty kind]


-- Here
ppr_hs_tyvar PprInterface tv_name = ppr PprForUser tv_name
ppr_hs_tyvar other_sty    tv_name = ppr other_sty tv_name

ppr_forall sty ctxt_prec [] [] ty
   = ppr_mono_ty sty ctxt_prec ty
ppr_forall sty ctxt_prec tvs ctxt ty
   = ppSep [ppStr "_forall_", ppBracket (interppSP sty tvs),
	    pprContext sty ctxt,  ppStr "=>",
	    pprHsType sty ty]

pprContext :: (Outputable name) => PprStyle -> (Context name) -> Pretty
pprContext sty []	        = ppNil
pprContext sty context
  = ppCat [ppCurlies (ppIntersperse pp'SP (map ppr_assert context))]
  where
    ppr_assert (clas, ty) = ppCat [ppr sty clas, ppr sty ty]
\end{code}

\begin{code}
pREC_TOP = (0 :: Int)
pREC_FUN = (1 :: Int)
pREC_CON = (2 :: Int)

maybeParen :: Bool -> Pretty -> Pretty
maybeParen True  p = ppParens p
maybeParen False p = p
	
-- printing works more-or-less as for Types

pprHsType, pprParendHsType :: (Outputable name) => PprStyle -> HsType name -> Pretty

pprHsType sty ty       = ppr_mono_ty sty pREC_TOP ty
pprParendHsType sty ty = ppr_mono_ty sty pREC_CON ty

ppr_mono_ty sty ctxt_prec (HsPreForAllTy ctxt ty)     = ppr_forall sty ctxt_prec [] ctxt ty
ppr_mono_ty sty ctxt_prec (HsForAllTy tvs ctxt ty)    = ppr_forall sty ctxt_prec tvs ctxt ty

ppr_mono_ty sty ctxt_prec (MonoTyVar name) = ppr_hs_tyvar sty name

ppr_mono_ty sty ctxt_prec (MonoFunTy ty1 ty2)
  = let p1 = ppr_mono_ty sty pREC_FUN ty1
	p2 = ppr_mono_ty sty pREC_TOP ty2
    in
    maybeParen (ctxt_prec >= pREC_FUN)
	       (ppSep [p1, ppBeside (ppStr "-> ") p2])

ppr_mono_ty sty ctxt_prec (MonoTupleTy _ tys)
 = ppParens (ppInterleave ppComma (map (ppr sty) tys))

ppr_mono_ty sty ctxt_prec (MonoListTy _ ty)
 = ppBesides [ppLbrack, ppr_mono_ty sty pREC_TOP ty, ppRbrack]

ppr_mono_ty sty ctxt_prec (MonoTyApp tycon tys)
  = let pp_tycon = ppr sty tycon in
    if null tys then
	pp_tycon
    else 
	maybeParen (ctxt_prec >= pREC_CON)
		   (ppCat [pp_tycon, ppInterleave ppNil (map (ppr_mono_ty sty pREC_CON) tys)])

ppr_mono_ty sty ctxt_prec (MonoDictTy clas ty)
  = ppCurlies (ppCat [ppr sty clas, ppr_mono_ty sty pREC_CON ty])
	-- Curlies are temporary
\end{code}


%************************************************************************
%*									*
\subsection{Comparison}
%*									*
%************************************************************************

We do define a specialised equality for these \tr{*Type} types; used
in checking interfaces.  Most any other use is likely to be {\em
wrong}, so be careful!

\begin{code}
cmpHsTyVar :: (a -> a -> TAG_) -> HsTyVar a -> HsTyVar a -> TAG_
cmpHsType :: (a -> a -> TAG_) -> HsType a -> HsType a -> TAG_
cmpContext  :: (a -> a -> TAG_) -> Context  a -> Context  a -> TAG_

cmpHsTyVar cmp (UserTyVar v1)    (UserTyVar v2)    = v1 `cmp` v2
cmpHsTyVar cmp (IfaceTyVar v1 _) (IfaceTyVar v2 _) = v1 `cmp` v2
cmpHsTyVar cmp (UserTyVar _)	 other		   = LT_
cmpHsTyVar cmp other1	 	 other2		   = GT_


-- We assume that HsPreForAllTys have been smashed by now.
# ifdef DEBUG
cmpHsType _ (HsPreForAllTy _ _) _ = panic# "cmpHsType:HsPreForAllTy:1st arg"
cmpHsType _ _ (HsPreForAllTy _ _) = panic# "cmpHsType:HsPreForAllTy:2nd arg"
# endif

cmpHsType cmp (HsForAllTy tvs1 c1 t1) (HsForAllTy tvs2 c2 t2)
  = cmpList (cmpHsTyVar cmp) tvs1 tvs2  `thenCmp`
    cmpContext cmp c1 c2    		`thenCmp`
    cmpHsType cmp t1 t2

cmpHsType cmp (MonoTyVar n1) (MonoTyVar n2)
  = cmp n1 n2

cmpHsType cmp (MonoTupleTy _ tys1) (MonoTupleTy _ tys2)
  = cmpList (cmpHsType cmp) tys1 tys2
cmpHsType cmp (MonoListTy _ ty1) (MonoListTy _ ty2)
  = cmpHsType cmp ty1 ty2

cmpHsType cmp (MonoTyApp tc1 tys1) (MonoTyApp tc2 tys2)
  = cmp tc1 tc2 `thenCmp`
    cmpList (cmpHsType cmp) tys1 tys2

cmpHsType cmp (MonoFunTy a1 b1) (MonoFunTy a2 b2)
  = cmpHsType cmp a1 a2 `thenCmp` cmpHsType cmp b1 b2

cmpHsType cmp (MonoDictTy c1 ty1)   (MonoDictTy c2 ty2)
  = cmp c1 c2 `thenCmp` cmpHsType cmp ty1 ty2

cmpHsType cmp ty1 ty2 -- tags must be different
  = let tag1 = tag ty1
	tag2 = tag ty2
    in
    if tag1 _LT_ tag2 then LT_ else GT_
  where
    tag (MonoTyVar n1)		= (ILIT(1) :: FAST_INT)
    tag (MonoTupleTy _ tys1)	= ILIT(2)
    tag (MonoListTy _ ty1)	= ILIT(3)
    tag (MonoTyApp tc1 tys1)	= ILIT(4)
    tag (MonoFunTy a1 b1)	= ILIT(5)
    tag (MonoDictTy c1 ty1)	= ILIT(7)
    tag (HsForAllTy _ _ _)	= ILIT(8)
    tag (HsPreForAllTy _ _)	= ILIT(9)

-------------------
cmpContext cmp a b
  = cmpList cmp_ctxt a b
  where
    cmp_ctxt (c1, ty1) (c2, ty2)
      = cmp c1 c2 `thenCmp` cmpHsType cmp ty1 ty2
\end{code}
