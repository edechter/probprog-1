(declare (usual-integrations))

(load "pp-records")
(load "constants")
(load "eq-properties")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Globals and initialization ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define DEFAULT-MH-STEPS 100)

(define *niter-left*)
(define *current-ptrace*)
(define *alternative-ptrace*)
(define *forward-score*)
(define *backward-score*)
(define *common-ptrace-prefix-length*)
(define *top-level* #f) ;; should only be rebound dynamically (i.e. should stay #f in global scope)
(define *niter-done* 0) ;; only interesting when resuming runs

(define (reset)
  (set! *niter-left* DEFAULT-MH-STEPS)
  (set! *current-ptrace* (ptrace:new '() '()))
  (set! *alternative-ptrace* #f))
(reset)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward-sampling with bookkeeping ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (sample name sampler log-likelihood parameters proposer)
  (if (default-object? proposer)
    (set! proposer (prior-proposer sampler log-likelihood parameters)))

  (let ((val (call-with-current-continuation
               (lambda (k)
                 (let ((val (sampler parameters)))
                   (ptrace:add-choice! (choice:new name parameters proposer val k))
                   val)))))
    (ptrace:add-prior-score! (log-likelihood val parameters))
    val))

(define ((prior-proposer sampler log-likelihood parameters) choice)
  (let ((new-val (sampler parameters))
        (old-val (choice:val choice)))
    (let ((forward-score (log-likelihood new-val parameters))
          (backward-score (log-likelihood old-val parameters)))
      (set! *forward-score* forward-score)   ;; forward means alternative -> current
      (set! *backward-score* backward-score) ;; backward means current -> alternative
      new-val)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;:
;; Emit and MH over traces ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;:

(define (emit var observed-value #!optional likelihood-function)
  (if (default-object? likelihood-function)
    (set! likelihood-function likelihood:exact))

  (ptrace:set-likelihood-score! *current-ptrace* (likelihood-function var observed-value))
  (call-with-current-continuation
    (lambda (k)
      (ptrace:set-emit-continuation! *current-ptrace* k)
      (choose-ptrace (MH-sample-ptrace))))
  (set! *niter-done* (+ *niter-done* 1))
  (if (> *niter-left* 0)
    (try-another)
    (if (not *top-level*)
      (reset))))

(define (MH-sample-ptrace)
  (if (not *alternative-ptrace*)
    *current-ptrace*
    (let ((forward-choice-prob (flo:negate (flo:log (exact->inexact (ptrace:length *alternative-ptrace*)))))
          (backward-choice-prob (flo:negate (flo:log (exact->inexact (ptrace:length *current-ptrace*)))))
          (current-prior (prior-score *current-ptrace*))
          (alternative-prior (prior-score *alternative-ptrace*))
          (current-likelihood (ptrace:likelihood-score *current-ptrace*))
          (alternative-likelihood (ptrace:likelihood-score *alternative-ptrace*)))
      (cond ((flo:= alternative-likelihood neginf) *current-ptrace*)
            ((flo:= current-likelihood neginf) *alternative-ptrace*)
            (else (let ((accept-current-probability
                          (flo:sum (flo:- current-prior alternative-prior)
                                   (flo:- current-likelihood alternative-likelihood)
                                   (flo:- backward-choice-prob forward-choice-prob)
                                   (flo:- *backward-score* *forward-score*))))
                    (if (flo:< (flo:log (random 1.0)) accept-current-probability)
                      *current-ptrace*
                      *alternative-ptrace*)))))))

(define (prior-score ptrace)
  (list-ref (reverse (ptrace:prior-scores ptrace)) *common-ptrace-prefix-length*))

(define (choose-ptrace ptrace)
  (set! *current-ptrace* ptrace)
  (within-continuation (ptrace:emit-continuation ptrace) (lambda () #!unspecific)))

(define (try-another)
  (set! *niter-left* (- *niter-left* 1))
  (set! *alternative-ptrace* *current-ptrace*)
  (let* ((proposal-index (random (ptrace:length *current-ptrace*)))
         (new-ptrace (ptrace:head *current-ptrace* proposal-index))
         (choice (list-ref (reverse (ptrace:choices *current-ptrace*)) proposal-index))
         (k (choice:continuation choice)))
    (set! *common-ptrace-prefix-length* (ptrace:length new-ptrace))
    (set! *current-ptrace* new-ptrace)
    (within-continuation k (lambda () (propose choice)))))

(define (propose choice)
  (let ((new-val ((choice:proposer choice) choice))
        (new-choice (choice:copy choice)))
    (choice:set-val! new-choice new-val)
    (ptrace:add-choice! new-choice)
    new-val))

;;;;;;;;;;;;;;;;;;;;
;; Resumable runs ;;
;;;;;;;;;;;;;;;;;;;;

(define (run thunk niter)
  (fluid-let ((*niter-left* niter)
              (*niter-done* 0)
              (*current-ptrace* (ptrace:new '() '()))
              (*alternative-ptrace* #f)
              (*backward-score* #f)
              (*forward-score* #f)
              (*backward-score* #f)
              (*common-ptrace-prefix-length* #f))

             (call-with-current-continuation
               (lambda (k)
                 (fluid-let ((*top-level* k))
                            (let ((val (thunk)))
                              (eq-put! thunk 'last-ptrace *current-ptrace*)
                              (eq-put! thunk 'total-iterations *niter-done*)
                              (*top-level* (thunk))))))))

(define (resume thunk niter)
  (call-with-current-continuation
    (lambda (k)
      (within-continuation
        (ptrace:emit-continuation (eq-get thunk 'last-ptrace))
        (lambda () (set! *niter-left* niter) (set! *top-level* k) #!unspecific)))))

