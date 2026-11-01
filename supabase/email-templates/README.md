# MedConsult auth emails

Paste each file into Supabase: **Authentication → Emails → Templates**. The `.subject.txt` file is the subject line.

| Supabase template | Body | Subject |
|---|---|---|
| Confirm sign up | confirm-signup.html | confirm-signup.subject.txt |
| Invite user | invite.html | invite.subject.txt |
| Magic link | magic-link.html | magic-link.subject.txt |
| Reset password | reset-password.html | reset-password.subject.txt |

Keep `{{ .ConfirmationURL }}` and `{{ .Email }}` exactly as written. Colours come from the site (azure `#2b7fff`, ink `#0a0a0b`).
Emails never carry health information. Sender (name `MedConsult`, `noreply@medconsult.africa`) is set under **SMTP Settings**.
