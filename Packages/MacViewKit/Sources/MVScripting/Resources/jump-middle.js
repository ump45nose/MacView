// @name 跳到中间页
// @description 跳到当前书的中间页
const book = mv.book();
if (book && book.pageCount > 0) mv.goTo(Math.floor(book.pageCount / 2));
