-- OPTIONAL hardening, NOT applied yet. Visitors do not need to call the admin helper function.
revoke execute on function public.is_review_admin() from public, anon;
grant  execute on function public.is_review_admin() to authenticated;
