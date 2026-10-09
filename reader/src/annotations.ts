import { collapse, compare } from '../../vendor/foliate-js/epubcfi.js';

export type Annotation = {
  id: string; kind: 'bookmark' | 'highlight'; cfi: string; text: string;
  chapter: string; percentage: number; color: string; createdAt: number;
};
export const highlightColors = ['#fff176', '#a5d6a7', '#90caf9', '#f48fb1', '#ce93d8'];
export function onPage(cfi: string, location: string) {
  try { return compare(collapse(cfi), collapse(location)) >= 0 && compare(collapse(cfi), collapse(location, true)) <= 0; }
  catch { return cfi === location; }
}
