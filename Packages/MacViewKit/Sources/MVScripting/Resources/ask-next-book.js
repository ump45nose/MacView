// @name 读完询问下一本
// @description 读到最后一页时询问是否打开下一本
// @event pageEnd
if (mv.event && mv.event.direction === "forward" && mv.confirm("打开下一本？")) {
    mv.command("book.next");
}
