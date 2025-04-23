#include <stddef.h> 
#include <jni.h>
int process_and_transform_matrix(const int** matrix, size_t rows, size_t cols, int** transposed_matrix) {
    // Handle cases where matrix is empty
    if (rows == 0 || cols == 0) {
        return 0; // Empty matrix, nothing to transpose, consider it success.
    }

    // Validate top-level pointers if matrix is not empty
    if (matrix == NULL || transposed_matrix == NULL) {
        return -1; // Error: Input or output matrix pointer is NULL for a non-empty matrix.
    }

    // Validate that each row pointer in the input matrix is not NULL
    for (size_t i = 0; i < rows; ++i) {
        // pointer arithmetic: (matrix + i) gives the address of the i-th element in the 'matrix' array (which is an int**)
        // * (matrix + i) dereferences that address to get the actual pointer to the i-th row (which is an int*)
        if (*(matrix + i) == NULL) {
            return -1; // Error: Encountered a NULL row pointer in the input matrix.
        }
    }

    // Validate that each row pointer in the output matrix is not NULL
     for (size_t j = 0; j < cols; ++j) {
        // pointer arithmetic: (transposed_matrix + j) gives the address of the j-th element in the 'transposed_matrix' array
        // * (transposed_matrix + j) dereferences that address to get the actual pointer to the j-th row
        if (*(transposed_matrix + j) == NULL) {
            return -1; // Error: Encountered a NULL row pointer in the output matrix.
        }
    }


    // Perform the matrix transposition using explicit pointer arithmetic
    // Iterate through the rows of the original matrix (0 to rows-1)
    for (size_t i = 0; i < rows; ++i) {
        // Get the pointer to the beginning of the current row (row 'i') in the input matrix.
        // *(matrix + i) is equivalent to matrix[i], which is a pointer to the start of row i.
        const int* current_input_row_ptr = *(matrix + i);

        // Iterate through the columns of the original matrix (0 to cols-1)
        for (size_t j = 0; j < cols; ++j) {
            // Get the value of the element at original_matrix[i][j].
            // current_input_row_ptr + j points to the element at column 'j' within the current input row.
            // *(current_input_row_ptr + j) dereferences to get the value at matrix[i][j].
            int value = *(current_input_row_ptr + j); // Equivalent to value = matrix[i][j];

            // Now, write this value to the transposed matrix at transposed_matrix[j][i].
            // Get the pointer to the beginning of the target row (row 'j') in the transposed matrix.
            // *(transposed_matrix + j) is equivalent to transposed_matrix[j], which is a pointer to the start of row j in the transposed matrix.
            int* target_output_row_ptr = *(transposed_matrix + j);

            // Write the value at the correct position within the target output row.
            // target_output_row_ptr + i points to the element at column 'i' within the current output row (row 'j').
            // *(target_output_row_ptr + i) dereferences to write the value at transposed_matrix[j][i].
            *(target_output_row_ptr + i) = value; // Equivalent to transposed_matrix[j][i] = value;
        }
    }

    // If we reached here, the transposition was successful.
    return 0;
}


JNIEXPORT jint JNICALL Java_com_example_JniExample_calculateSum(
    JNIEnv *env,       
    jobject thisObject                  
) {
    int sum = 0;
    for (int i = 1; i <= 100; ++i) {
        sum += i;
    }

    return (jint)sum;
}

// JNIEXPORT jint JNICALL Java_Main_intMethod(
//     JNIEnv *env, jobject obj, jint i)
// {
//     Java_com_example_JniExample_calculateSum(env, obj);
//     return i * i;
// }

// Note: This code snippet contains only function definitions and no main() function.
// It also avoids console output (like std::cout).
// These functions are intended to be called from other parts of a larger C++ program.