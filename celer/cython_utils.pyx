# Author: Mathurin Massias <mathurin.massias@gmail.com>
#         Alexandre Gramfort <alexandre.gramfort@inria.fr>
#         Joseph Salmon <joseph.salmon@telecom-paristech.fr>
# License: BSD 3 clause

cimport cython
cimport numpy as np

from scipy.linalg.cython_blas cimport ddot, dasum, daxpy, dnrm2, dcopy, dscal
from scipy.linalg.cython_blas cimport sdot, sasum, saxpy, snrm2, scopy, sscal
from scipy.linalg.cython_lapack cimport sposv, dposv
from libc.math cimport fabs, log, exp, sqrt
from numpy.math cimport INFINITY
from cython cimport floating


cdef:
    int LASSO = 0
    int LOGREG = 1
    int inc = 1


cdef floating fdot(int * n, floating * x, int * inc1, floating * y,
                        int * inc2) nogil:
    if floating is double:
        return ddot(n, x, inc1, y, inc2)
    else:
        return sdot(n, x, inc1, y, inc2)


cdef floating fasum(int * n, floating * x, int * inc) nogil:
    if floating is double:
        return dasum(n, x, inc)
    else:
        return sasum(n, x, inc)


cdef void faxpy(int * n, floating * alpha, floating * x, int * incx,
                     floating * y, int * incy) nogil:
    if floating is double:
        daxpy(n, alpha, x, incx, y, incy)
    else:
        saxpy(n, alpha, x, incx, y, incy)


cdef floating fnrm2(int * n, floating * x, int * inc) nogil:
    if floating is double:
        return dnrm2(n, x, inc)
    else:
        return snrm2(n, x, inc)


cdef void fcopy(int * n, floating * x, int * incx, floating * y,
                     int * incy) nogil:
    if floating is double:
        dcopy(n, x, incx, y, incy)
    else:
        scopy(n, x, incx, y, incy)


cdef void fscal(int * n, floating * alpha, floating * x,
                     int * incx) nogil:
    if floating is double:
        dscal(n, alpha, x, incx)
    else:
        sscal(n, alpha, x, incx)


cdef void fposv(char * uplo, int * n, int * nrhs, floating * a,
                     int * lda, floating * b, int * ldb, int * info) nogil:
    if floating is double:
        dposv(uplo, n, nrhs, a, lda, b, ldb, info)
    else:
        sposv(uplo, n, nrhs, a, lda, b, ldb, info)


cdef inline floating ST(floating x, floating u) nogil:
    if x > u:
        return x - u
    elif x < - u:
        return x + u
    else:
        return 0


cdef floating log_1pexp(floating x) nogil:
    """Compute log(1. + exp(x)) while avoiding over/underflow."""
    if x < - 18:
        return exp(x)
    elif x > 18:
        return x
    else:
        return log(1. + exp(x))


cdef inline floating xlogx(floating x) nogil:
    if x < 1e-10:
        return 0.
    else:
        return x * log(x)

cdef inline floating Nh(floating x) nogil:
    """Negative entropy of scalar x."""
    if 0. <= x <= 1.:
        return xlogx(x) + xlogx(1. - x)
    else:
        # print(x)
        return INFINITY  # not - INFINITY


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef inline floating sigmoid(floating x) nogil:
    return 1. / (1. + exp(- x))


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef floating primal_logreg(floating alpha, int n_samples, floating * Xw,
                            floating * y, int n_features, floating * w) nogil:
    cdef int inc = 1
    cdef floating p_obj = alpha * fasum(&n_features, &w[0], &inc)
    cdef int i = 0
    for i in range(n_samples):
        p_obj += log_1pexp(- y[i] * Xw[i])
    return p_obj


# todo check normalization by 1 / n_samples everywhere
@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef floating primal_lasso(floating alpha, int n_samples, floating * R,
                         int n_features, floating * w) nogil:
    cdef int inc = 1
    cdef floating p_obj = alpha * fasum(&n_features, w, &inc)
    p_obj += fdot(&n_samples, R, &inc, R, &inc) / (2. * n_samples)
    return p_obj


cdef floating primal(
    int pb, floating alpha, int n_samples, floating * R, floating * y,
    int n_features, floating * w) nogil:
    if pb == LASSO:
        return primal_lasso(alpha, n_samples, &R[0], n_features, &w[0])
    else:
        return primal_logreg(alpha, n_samples, &R[0], &y[0],  n_features,
                             &w[0])


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef floating dual_lasso(int n_samples, floating alpha, floating norm_y2,
                       floating * theta, floating * y) nogil:
    """Theta must be feasible"""
    cdef int i
    cdef floating d_obj = 0.
    for i in range(n_samples):
        d_obj -= (y[i] / (alpha * n_samples) - theta[i]) ** 2
    d_obj *= 0.5 * alpha ** 2 * n_samples
    d_obj += norm_y2 / (2. * n_samples)
    return d_obj


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef floating dual_logreg(int n_samples, floating alpha, floating * theta,
                          floating * y) nogil:
    """Compute dual objective value at theta, which must be feasible."""
    cdef int i
    cdef floating d_obj = 0.
    for i in range(n_samples):
        d_obj -= Nh(alpha * y[i] * theta[i])
    return d_obj


cdef floating dual(int pb, int n_samples, floating alpha, floating norm_y2,
                   floating * theta, floating * y) nogil:
    if pb == LASSO:
        return dual_lasso(n_samples, alpha, norm_y2, &theta[0], &y[0])
    else:
        return dual_logreg(n_samples, alpha, &theta[0], &y[0])


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void create_dual_pt(
        int pb, int n_samples, floating alpha, floating * out,
        floating * R, floating * y) nogil:
    """It is scaled by alpha for both Lasso and Logreg"""
    cdef floating tmp = 1. / alpha
    if pb == LASSO:  # out = R / alpha
        fcopy(&n_samples, &R[0], &inc, &out[0], &inc)
    else:  # out = y * sigmoid(-y * Xw) / alpha
        for i in range(n_samples):
            out[i] = y[i] * sigmoid(-y[i] * R[i])

    fscal(&n_samples, &tmp, &out[0], &inc)


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef int create_accel_pt(
    int pb, int n_samples, int n_features, int K, int epoch, int gap_freq,
    floating alpha,
    floating * R, floating * out, floating * last_K_R, floating[:, :] U,
    floating[:, :] UtU, floating[:] onesK, floating[:] y):

    # solving linear system in cython
    # doc at https://software.intel.com/en-us/node/468894

    cdef char * char_U = 'U'
    cdef int one = 1
    cdef int Kminus1 = K - 1
    cdef int inc = 1
    cdef floating sum_z
    cdef int info_dposv

    cdef int i, j, k
    cdef floating tmp = 1. / alpha

    if epoch // gap_freq < K:
        # last_K_R[it // f_gap] = R:
        fcopy(&n_samples, R, &inc,
              &last_K_R[(epoch // gap_freq) * n_samples], &inc)
    else:
        for k in range(K - 1):
            fcopy(&n_samples, &last_K_R[(k + 1) * n_samples], &inc,
                  &last_K_R[k * n_samples], &inc)
        fcopy(&n_samples, R, &inc, &last_K_R[(K - 1) * n_samples], &inc)
        for k in range(K - 1):
            for i in range(n_samples):
                U[k, i] = last_K_R[(k + 1) * n_samples + i] - last_K_R[k * n_samples + i]

        for k in range(K - 1):
            for j in range(k, K - 1):
                UtU[k, j] = fdot(&n_samples, &U[k, 0], &inc,
                                  &U[j, 0], &inc)
                UtU[j, k] = UtU[k, j]

        # refill onesK with ones because it has been overwritten
        # by dposv
        for k in range(K - 1):
            onesK[k] = 1.

        fposv(char_U, &Kminus1, &one, &UtU[0, 0], &Kminus1,
               &onesK[0], &Kminus1, &info_dposv)

        # onesK now holds the solution in x to UtU dot x = onesK
        if info_dposv != 0:
            # don't use accel for this iteration
            for k in range(K - 2):
                onesK[k] = 0
            onesK[K - 2] = 1

        sum_z = 0.
        for k in range(K - 1):
            sum_z += onesK[k]
        for k in range(K - 1):
            onesK[k] /= sum_z

        for i in range(n_samples):
            out[i] = 0.
        for k in range(K - 1):
            for i in range(n_samples):
                out[i] += onesK[k] * last_K_R[k * n_samples + i]

        if pb == LOGREG:
            for i in range(n_samples):
                out[i] = y[i] * sigmoid(- y[i] * out[i])

        fscal(&n_samples, &tmp, &out[0], &inc)
        # out now holds the extrapolated dual point:
        # LASSO: (y - Xw) / alpha
        # LOGREG:  y * sigmoid(-y * Xw) / alpha

    return info_dposv


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cpdef void compute_norms_X_col(
        bint is_sparse, floating[:] norms_X_col, int n_samples, int n_features,
        floating[::1, :] X, floating[:] X_data, int[:] X_indices,
        int[:] X_indptr, floating[:] X_mean):
    cdef int j, startptr, endptr
    cdef floating tmp, X_mean_j

    for j in range(n_features):
        if is_sparse:
            startptr = X_indptr[j]
            endptr = X_indptr[j + 1]
            X_mean_j = X_mean[j]
            tmp = 0.
            for i in range(startptr, endptr):
                tmp += (X_data[i] - X_mean_j) ** 2
            tmp += (n_samples - endptr + startptr) * X_mean_j ** 2
            norms_X_col[j] = sqrt(tmp)
        else:
            norms_X_col[j] = fnrm2(&n_samples, &X[0, j], &inc)


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cpdef void compute_residuals(
        bint is_sparse, floating[:] R, floating[:] w,
        floating[:] y, int pb, bint center, int n_samples,
        int n_features, floating[::1, :] X, floating[:] X_data,
        int[:] X_indices, int[:] X_indptr, floating[:] X_mean):
    # R holds residuals if LASSO, Xw for LOGREG
    cdef int i, j, startptr, endptr
    cdef floating tmp, X_mean_j
    cdef int inc = 1

    for j in range(n_features):
        if w[j] != 0:
            if is_sparse:
                startptr, endptr = X_indptr[j], X_indptr[j + 1]
                for i in range(startptr, endptr):
                    R[X_indices[i]] += w[j] * X_data[i]
                if center:
                    X_mean_j = X_mean[j]
                    for i in range(n_samples):
                        R[i] -= X_mean_j * w[j]
            else:
                tmp = w[j]
                faxpy(&n_samples, &tmp, &X[0, j], &inc, &R[0], &inc)
    # currently R = X @ w, update for LASSO:
    if pb == LASSO:
        for i in range(n_samples):
            R[i] = y[i] - R[i]


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef floating compute_dual_scaling(
        bint is_sparse, int pb, int n_features, int n_samples,
        floating * theta, floating[::1, :] X, floating[:] X_data,
        int[:] X_indices, int[:] X_indptr, int ws_size, int * C,
        uint8 * screened, floating[:] X_mean, bint center, bint positive) nogil:
    """compute norm(X.T.dot(theta), ord=inf),
    with X restricted to features (columns) with indices in array C.
    if ws_size == n_features, C=np.arange(n_features is used)"""
    cdef floating Xj_theta
    cdef floating scal = 0.
    cdef floating theta_sum = 0.
    cdef int i, j, Cj, startptr, endptr

    if is_sparse:
        if center:
            for i in range(n_samples):
                theta_sum += theta[i]

    if ws_size == n_features: # scaling wrt all features
        for j in range(n_features):
            if screened[j]:
                continue
            if is_sparse:
                startptr = X_indptr[j]
                endptr = X_indptr[j + 1]
                Xj_theta = 0.
                for i in range(startptr, endptr):
                    Xj_theta += X_data[i] * theta[X_indices[i]]
                if center:
                    Xj_theta -= theta_sum * X_mean[j]
            else:
                Xj_theta = fdot(&n_samples, &theta[0], &inc, &X[0, j], &inc)

            if not positive:
                Xj_theta = fabs(Xj_theta)
            scal = max(scal, Xj_theta)
    else: # scaling wrt features in C only
        for j in range(ws_size):
            Cj = C[j]
            if is_sparse:
                startptr = X_indptr[Cj]
                endptr = X_indptr[Cj + 1]
                Xj_theta = 0.
                for i in range(startptr, endptr):
                    Xj_theta += X_data[i] * theta[X_indices[i]]
                if center:
                    Xj_theta -= theta_sum * X_mean[j]
            else:
                Xj_theta = fdot(&n_samples, &theta[0], &inc, &X[0, Cj], &inc)

            if not positive:
                Xj_theta = fabs(Xj_theta)

            scal = max(scal, Xj_theta)
    return scal


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void set_prios(
    bint is_sparse, int pb, int n_samples, int n_features, floating * theta,
    floating[::1, :] X, floating[:] X_data, int[:] X_indices, int[:] X_indptr,
    floating * norms_X_col, floating * prios, uint8 * screened, floating radius,
    int * n_screened, bint positive) nogil:
    cdef int i, j, startptr, endptr
    cdef floating Xj_theta

    for j in range(n_features):
        if screened[j]:
            prios[j] = 10000
            continue
        if is_sparse:
            Xj_theta = 0
            startptr = X_indptr[j]
            endptr = X_indptr[j + 1]
            for i in range(startptr, endptr):
                Xj_theta += theta[X_indices[i]] * X_data[i]
        else:
            Xj_theta = fdot(&n_samples, &theta[0], &inc, &X[0, j], &inc)

        if positive:
            prios[j] = fabs(Xj_theta - 1.) / norms_X_col[j]
        else:
            prios[j] = (1. - fabs(Xj_theta)) / norms_X_col[j]

        if prios[j] > radius:
            screened[j] = True
            n_screened[0] += 1