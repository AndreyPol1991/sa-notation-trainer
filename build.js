/* Собирает standalone-страницу index.html из фрагмента trainer.html.
   trainer.html — исходник для публикации артефактом (без doctype и head).
   index.html — то же самое, но полноценный документ: для localhost и GitHub Pages.
   Запуск:  node build.js                                                    */
const fs = require('fs');
const path = require('path');

const src = path.join(__dirname, 'trainer.html');
const out = path.join(__dirname, 'index.html');
const body = fs.readFileSync(src, 'utf8');

const page = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Интерактивный тренажёр нотаций системного анализа: ERD, BPMN, UML, DFD. 22 модуля, 233 задачи, конструкторы схем.">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>%F0%9F%93%90</text></svg>">
</head>
<body>
${body}
</body>
</html>
`;

fs.writeFileSync(out, page, 'utf8');
console.log('index.html собран:', (page.length / 1024).toFixed(0) + ' КБ');
