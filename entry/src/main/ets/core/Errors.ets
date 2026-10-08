// Native BusinessError.message can be a number despite the Error type annotation.
export function errorMessage(error: Error): string {
  return error && typeof error.message === 'string' && error.message ? error.message : 'OPERATION_FAILED';
}
