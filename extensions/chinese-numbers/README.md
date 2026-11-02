# Chinese Numbers

Writes numbers in Chinese as you type them, and reads Chinese numbers back as
digits.

- **Convert to Chinese Numbers** turns digits such as `100111.11` into three
  rows: lowercase (十万零一百一十一点一一), uppercase financial numerals
  (壹拾万零壹佰壹拾壹点壹壹), and the amount in words for invoices and cheques
  (壹拾万零壹佰壹拾壹元壹角壹分), rounded to the fen, with 整 when it stops at
  元 or 角. Type Chinese instead, such as 一万二千, 二〇二六, 一万五, or
  人民币壹佰元伍角, and it shows the digits. Return pastes the row into the
  app you were in; ⌘⇧C copies it.

It takes thousands separators, `¥`, full-width digits, and a minus sign, and
goes up to 16 digits before the point (9999万亿). Zeros follow
《会计基础工作规范》: a run of zeros reads as one 零, and trailing zeros as
nothing.

Pasting needs Prism to have Accessibility access; without it, Prism copies the
row and says so. On Prism 0.1.1, which can’t paste from a list, Return copies.

Needs nothing beyond macOS and declares no capabilities: everything is worked
out from what you type, and nothing leaves your Mac.
