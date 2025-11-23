// Rust WASM module for Nexus runtime testing

#![no_std]

// Import panic handler for no_std
use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

// WASI imports (will be provided by Nexus runtime)
extern "C" {
    fn fd_write(fd: u32, iovs: *const IoVec, iovs_len: u32, nwritten: *mut u32) -> u32;
}

#[repr(C)]
struct IoVec {
    ptr: u32,
    len: u32,
}

/// Print to stdout via WASI
fn print(msg: &str) {
    let iov = IoVec {
        ptr: msg.as_ptr() as u32,
        len: msg.len() as u32,
    };

    let mut nwritten: u32 = 0;

    unsafe {
        fd_write(1, &iov, 1, &mut nwritten);
    }
}

/// Simple hello world function
#[no_mangle]
pub extern "C" fn hello() -> i32 {
    print("Hello from Rust WASM!\n");
    42
}

/// Add two numbers
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// Fibonacci sequence
#[no_mangle]
pub extern "C" fn fibonacci(n: i32) -> i32 {
    if n <= 1 {
        return n;
    }
    fibonacci(n - 1) + fibonacci(n - 2)
}

/// String length calculation
#[no_mangle]
pub extern "C" fn strlen(ptr: *const u8, max_len: u32) -> u32 {
    let mut len = 0;
    unsafe {
        while len < max_len && *ptr.add(len as usize) != 0 {
            len += 1;
        }
    }
    len
}

/// Memory allocation test
#[no_mangle]
pub extern "C" fn alloc_test(size: u32) -> *mut u8 {
    // In a real implementation with std, would use Vec
    // For no_std, we'll return a fixed address
    0x1000 as *mut u8
}

/// Compute factorial
#[no_mangle]
pub extern "C" fn factorial(n: u32) -> u32 {
    match n {
        0 | 1 => 1,
        _ => n * factorial(n - 1),
    }
}

/// Sum array of numbers
#[no_mangle]
pub extern "C" fn sum_array(ptr: *const i32, len: u32) -> i32 {
    let mut sum = 0;
    for i in 0..len {
        unsafe {
            sum += *ptr.add(i as usize);
        }
    }
    sum
}

/// Check if number is prime
#[no_mangle]
pub extern "C" fn is_prime(n: u32) -> bool {
    if n < 2 {
        return false;
    }
    if n == 2 {
        return true;
    }
    if n % 2 == 0 {
        return false;
    }

    let mut i = 3;
    while i * i <= n {
        if n % i == 0 {
            return false;
        }
        i += 2;
    }
    true
}

/// Matrix multiplication (2x2 matrices)
#[no_mangle]
pub extern "C" fn matrix_mult_2x2(
    a: *const i32,
    b: *const i32,
    result: *mut i32,
) {
    unsafe {
        *result.add(0) = *a.add(0) * *b.add(0) + *a.add(1) * *b.add(2);
        *result.add(1) = *a.add(0) * *b.add(1) + *a.add(1) * *b.add(3);
        *result.add(2) = *a.add(2) * *b.add(0) + *a.add(3) * *b.add(2);
        *result.add(3) = *a.add(2) * *b.add(1) + *a.add(3) * *b.add(3);
    }
}
