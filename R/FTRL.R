#' @import methods
#' @import Matrix
#' @import Rcpp
#' @importFrom R6 R6Class
#' @importFrom utils txtProgressBar setTxtProgressBar
#' @useDynLib FTRL

#' @name FTRL
#' @title Creates FTRL proximal model.
#' @description Creates 'Follow the Regularized Leader' model. Only logistic regression implemented at the moment.
#' @section Usage:
#' For usage details see \bold{Methods, Arguments and Examples} sections.
#' \preformatted{
#' ftrl = FTRL$new(alpha = 0.1, beta = 0.5, lambda = 0, l1_ratio = 1, dropout = 0, family = "binomial")
#' ftrl$partial_fit(X, y, n_threads  = 0, ...)
#' ftrl$predict(X, n_threads  = 0, ...)
#' ftrl$coef()
#' }
#' @format \code{\link{R6Class}} object.
#' @section Methods:
#' \describe{
#'   \item{\code{FTRL$new(alpha = 0.1, beta = 0.5, lambda = 0, l1_ratio = 1, dropout = 0, family = "binomial")}}{Constructor
#'   for FTRL model. For description of arguments see \bold{Arguments} section.}
#'   \item{\code{$partial_fit(X, y, n_threads  = 0, ...)}}{fits/updates model given input matrix \code{X} and target vector \code{y}.
#'   \code{X} shape = (n_samples, n_features)}
#'   \item{\code{$predict(X, n_threads  = 0, ...)}}{predicts output \code{X}}
#'   \item{\code{$coef()}}{ return coefficients of the regression model}
#'   \item{\code{$dump()}}{create dump of the model (actually \code{list} with current model parameters)}
#'   \item{\code{$load(x)}}{load/initialize model from dump)}
#'}
#' @field verbose \code{logical = TRUE} whether to display training inforamtion
#' @section Arguments:
#' \describe{
#'  \item{ftrl}{\code{FTRL} object}
#'  \item{X}{Input sparse matrix - native format is \code{Matrix::RsparseMatrix}.
#'  If \code{X} is in different format, model will try to convert it to \code{RsparseMatrix}
#'  with \code{as(X, "RsparseMatrix")} call}
#'  \item{alpha}{learning rate}
#'  \item{beta}{learning rate which controls decay. Please refer to FTRL paper for details.
#'  Usually convergense does not heavily depend on this parameter, so default value 0.5 is safe.}
#'  \item{lambda}{regularization parameter}
#'  \item{l1_ratio}{controls L1 vs L2 penalty mixing. 1 = Lasso regression, 0 = Ridge regression. Elastic net is in between.}
#'  \item{dropout}{dropout - percentage of random features to exclude from each sample. Kind of regularization.}
#'  \item{n_features}{number of features in model (number of columns in expected model matrix) }
#'  \item{family}{family of generalized linear model to solve. Only \code{binomial} (or logistic regression) supported at the moment.}
#' }
#' @export
#' @examples
#' library(FTRL)
#' library(Matrix)
#' i = sample(1000, 1000 * 100, TRUE)
#' j = sample(1000, 1000 * 100, TRUE)
#' y = sample(c(0, 1), 1000, TRUE)
#' x = sample(c(-1, 1), 1000 * 100, TRUE)
#' odd = seq(1, 99, 2)
#' x[i %in% which(y == 1) & j %in% odd] = 1
#' m = sparseMatrix(i = i, j = j, x = x, dims = c(1000, 1000), giveCsparse = FALSE)
#' X = as(m, "RsparseMatrix")
#'
#' ftrl = FTRL$new(alpha = 0.01, beta = 0.1, lambda = 10, l1_ratio = 1, dropout = 0)
#' ftrl$partial_fit(X, y, n_threads = 8)
#'
#' w = ftrl$coef()
#' head(w)
#' sum(w != 0)
#' p = ftrl$predict(m)
#' @export
FTRL = R6::R6Class(
  classname = "estimator",
  public = list(
    #-----------------------------------------------------------------
    initialize = function(alpha = 0.1, beta = 0.5,
                          lambda = 0, l1_ratio = 1,
                          dropout = 0, family = c("binomial")) {

      stopifnot(abs(dropout) < 1)
      stopifnot(l1_ratio <= 1 && l1_ratio >= 0)
      stopifnot(lambda >= 0 && alpha > 0 && beta > 0)
      family = match.arg(family);
      private$init_model_param(alpha = alpha, beta = beta,
                 lambda = lambda, l1_ratio = l1_ratio,
                 dropout = dropout, family = family)
    },
    #-----------------------------------------------------------------
    partial_fit = function(X, y, n_threads = 0, weights = rep(1, nrow(X)), ...) {
      # we can enforce to work only with sparse matrices:
      # stopifnot(inherits(X, "sparseMatrix"))
      if(!inherits(class(X), private$internal_matrix_format)) {
        # message(Sys.time(), " casting input matrix (class ", class(X), ") to ", private$internal_matrix_format)
        X = as(X, private$internal_matrix_format)
      }
      X_ncol = ncol(X)
      # init model during first first fit
      # if(is.null(private$is_initialized)) {
      if(!private$is_initialized) {
        private$init_model_state(n_features = X_ncol,
                                 z = numeric(X_ncol),
                                 n = numeric(X_ncol))
      }
      # on consequent updates check that we are wotking with input matrix with same numner of features
      stopifnot(X_ncol == private$model$n_features)
      # check number of samples = number of outcomes
      stopifnot(nrow(X) == length(y))
      # check no NA - anyNA() is by far fastest solution
      if(anyNA(X@x))
        stop("NA's in input matrix are not allowed")

      # NOTE THAT private$z and private$n will be updated in place during the call !!!
      p = ftrl_partial_fit(m = X, y = y, R_model = private$model, weights = weights,
                           do_update = TRUE, n_threads = n_threads)
      invisible(p)
    },
    #-----------------------------------------------------------------
    predict = function(X, n_threads = 0, ...) {
      stopifnot(private$is_initialized)
      # stopifnot(inherits(X, "sparseMatrix"))
      if(!inherits(class(X), private$internal_matrix_format)) {
        # message(Sys.time(), " casting input matrix (class ", class(X), ") to ", private$internal_matrix_format)
        X = as(X, private$internal_matrix_format)
      }
      stopifnot(ncol(X) == private$model$n_features)

      if(any(is.na(X)))
        stop("NA's in input matrix are not allowed")

      p = ftrl_partial_fit(m = X, y = numeric(0), R_model = private$model,
                           weights = rep(1, nrow(X)),
                           do_update = FALSE, n_threads = n_threads)
      return(p);
    },
    #-----------------------------------------------------------------
    coef = function() {
      get_ftrl_weights(private$model)
    },
    #-----------------------------------------------------------------
    dump = function() {
      # copy because we modify model in place
      model_dump = data.table::copy(private$model)
      class(model_dump) = "ftrl_model_dump"
      model_dump
    },
    #-----------------------------------------------------------------
    load = function(x) {
      if(class(x) != "ftrl_model_dump")
        stop("input should be class of 'ftrl_model_dump' -  list of model parameters")
      private$init_model_param(alpha = x$alpha, beta = x$beta,
                               lambda = x$lambda, l1_ratio = x$l1_ratio,
                               dropout = x$dropout, family = x$family)
      private$init_model_state(n_features = x$n_features,
                               z = data.table::copy(x$z),
                               n = data.table::copy(x$n))
    }
    #-----------------------------------------------------------------
  ),
  private = list(
    internal_matrix_format = "RsparseMatrix",
    # model parameters object
    model = list(
      alpha = NULL,
      beta = NULL,
      lambda = NULL,
      l1_ratio = NULL,
      dropout = NULL,
      n_features = NULL,
      family = NULL,
      family_code = NULL,
      z = NULL,
      n = NULL
    ),
    # whether we already called `partial_fit`
    # in this case we fix `n_features`
    is_initialized = FALSE,
    # function to init model
    init_model_param = function(alpha = 0.1, beta = 0.5,
                          lambda = 0, l1_ratio = 1,
                          dropout = 0, family = c("binomial")) {
      family = match.arg(family)

      private$model$alpha = alpha
      private$model$beta = beta
      private$model$lambda = lambda
      private$model$l1_ratio = l1_ratio
      private$model$dropout = dropout
      private$model$family = family
      private$model$family_code =
        switch(family,
               "binomial" = 1,
               "gaussian" = 2,
               "poisson" = 3,
               stop(sprintf("don't know how to work with family = '%s'", family))
               )
    },

    init_model_state = function(n_features = NULL, z = NULL, n = NULL) {
      # if(!is.null(private$is_initialized))
      if(private$is_initialized)
        stop("model already initialized!")

      private$is_initialized = TRUE

      if(!is.null(n_features)) private$model$n_features = n_features
      if(!is.null(z)) private$model$z = z
      if(!is.null(n)) private$model$n = n
    }
  )
)
