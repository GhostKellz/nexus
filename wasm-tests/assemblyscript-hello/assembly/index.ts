// AssemblyScript WASM module for Nexus runtime testing

/**
 * Simple hello world function
 */
export function hello(): i32 {
  // In a real implementation, would call console.log or WASI fd_write
  return 42;
}

/**
 * Add two numbers
 */
export function add(a: i32, b: i32): i32 {
  return a + b;
}

/**
 * Multiply two numbers
 */
export function multiply(a: i32, b: i32): i32 {
  return a * b;
}

/**
 * Calculate fibonacci number recursively
 */
export function fibonacci(n: i32): i32 {
  if (n <= 1) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
}

/**
 * Calculate fibonacci iteratively (more efficient)
 */
export function fibonacciIterative(n: i32): i32 {
  if (n <= 1) return n;

  let prev = 0;
  let curr = 1;

  for (let i = 2; i <= n; i++) {
    const next = prev + curr;
    prev = curr;
    curr = next;
  }

  return curr;
}

/**
 * Compute factorial
 */
export function factorial(n: u32): u32 {
  if (n <= 1) return 1;
  return n * factorial(n - 1);
}

/**
 * Check if number is prime
 */
export function isPrime(n: u32): bool {
  if (n < 2) return false;
  if (n == 2) return true;
  if (n % 2 == 0) return false;

  for (let i: u32 = 3; i * i <= n; i += 2) {
    if (n % i == 0) return false;
  }

  return true;
}

/**
 * Count primes up to n (Sieve of Eratosthenes)
 */
export function countPrimes(n: i32): i32 {
  if (n < 2) return 0;

  const isPrime = new Array<bool>(n + 1);
  isPrime.fill(true);
  isPrime[0] = false;
  isPrime[1] = false;

  for (let i = 2; i * i <= n; i++) {
    if (isPrime[i]) {
      for (let j = i * i; j <= n; j += i) {
        isPrime[j] = false;
      }
    }
  }

  let count = 0;
  for (let i = 2; i <= n; i++) {
    if (isPrime[i]) count++;
  }

  return count;
}

/**
 * Sum array of numbers
 */
export function sumArray(arr: Int32Array): i32 {
  let sum = 0;
  for (let i = 0; i < arr.length; i++) {
    sum += arr[i];
  }
  return sum;
}

/**
 * Find maximum in array
 */
export function findMax(arr: Int32Array): i32 {
  if (arr.length == 0) return 0;

  let max = arr[0];
  for (let i = 1; i < arr.length; i++) {
    if (arr[i] > max) max = arr[i];
  }
  return max;
}

/**
 * Bubble sort array
 */
export function bubbleSort(arr: Int32Array): void {
  const n = arr.length;

  for (let i = 0; i < n - 1; i++) {
    for (let j = 0; j < n - i - 1; j++) {
      if (arr[j] > arr[j + 1]) {
        const temp = arr[j];
        arr[j] = arr[j + 1];
        arr[j + 1] = temp;
      }
    }
  }
}

/**
 * Binary search in sorted array
 */
export function binarySearch(arr: Int32Array, target: i32): i32 {
  let left = 0;
  let right = arr.length - 1;

  while (left <= right) {
    const mid = (left + right) >>> 1;
    const midVal = arr[mid];

    if (midVal == target) return mid;
    if (midVal < target) left = mid + 1;
    else right = mid - 1;
  }

  return -1; // Not found
}

/**
 * String reverse (UTF-16)
 */
export function reverseString(s: string): string {
  let result = "";
  for (let i = s.length - 1; i >= 0; i--) {
    result += s.charAt(i);
  }
  return result;
}

/**
 * Count substring occurrences
 */
export function countSubstring(text: string, pattern: string): i32 {
  if (pattern.length == 0) return 0;

  let count = 0;
  let pos = 0;

  while (pos < text.length) {
    const index = text.indexOf(pattern, pos);
    if (index == -1) break;
    count++;
    pos = index + 1;
  }

  return count;
}

/**
 * Matrix multiplication (2x2)
 */
export function matrixMult2x2(
  a00: f64, a01: f64, a10: f64, a11: f64,
  b00: f64, b01: f64, b10: f64, b11: f64
): Float64Array {
  const result = new Float64Array(4);
  result[0] = a00 * b00 + a01 * b10;
  result[1] = a00 * b01 + a01 * b11;
  result[2] = a10 * b00 + a11 * b10;
  result[3] = a10 * b01 + a11 * b11;
  return result;
}

/**
 * Performance test: compute pi using Monte Carlo method
 */
export function computePiMonteCarlo(iterations: i32): f64 {
  let inside = 0;

  for (let i = 0; i < iterations; i++) {
    // Simple pseudo-random (not cryptographically secure)
    const x = Math.random();
    const y = Math.random();

    if (x * x + y * y <= 1.0) {
      inside++;
    }
  }

  return 4.0 * (inside as f64) / (iterations as f64);
}

/**
 * Memory stress test
 */
export function memoryTest(size: i32): i32 {
  const arr = new Int32Array(size);

  // Fill array
  for (let i = 0; i < size; i++) {
    arr[i] = i;
  }

  // Sum array
  let sum = 0;
  for (let i = 0; i < size; i++) {
    sum += arr[i];
  }

  return sum;
}
