extern "C" {

#include <bindings.cmacros.h>
#include <git2.h>

BC_INLINE3(git_blob_lookup, git_blob **, git_repository *, const git_oid *, int)
BC_INLINE1VOID(git_blob_free, git_blob *)
BC_INLINE3(git_tree_lookup, git_tree **, git_repository *, const git_oid *, int)
BC_INLINE1VOID(git_tree_free, git_tree *)
BC_INLINE3(git_commit_lookup, git_commit **, git_repository *,
    const git_oid *, int)
BC_INLINE1VOID(git_commit_free, git_commit *)

}
