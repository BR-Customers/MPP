// geometry.js
const r3 = (n) => Math.round(n * 1000) / 1000;

function placeImage(imgW, imgH, box) {
  const scale = Math.min(box.w / imgW, box.h / imgH);
  return { x: box.x, y: box.y, w: r3(imgW * scale), h: r3(imgH * scale) };
}

function toSlide(rect, placed, imgW, imgH, pad = 0) {
  const sx = placed.w / imgW, sy = placed.h / imgH;
  return {
    x: r3(placed.x + (rect.x - pad) * sx),
    y: r3(placed.y + (rect.y - pad) * sy),
    w: r3((rect.w + 2 * pad) * sx),
    h: r3((rect.h + 2 * pad) * sy),
  };
}

function insideImage(rect, imgW, imgH) {
  return rect.x >= 0 && rect.y >= 0 && rect.x + rect.w <= imgW && rect.y + rect.h <= imgH;
}

module.exports = { placeImage, toSlide, insideImage };
