#lang racket

(require "ck.rkt" (only-in "tree-unify.rkt" unify))
(provide =/= =/=-c =/=neq-c oc-prefix reify-prefix-dot)

;;; little helpers

(define recover/vars
  (lambda (p)
    (cond
      ((null? p) '())
      (else
        (let ((x (car (car p)))
              (v (cdr (car p)))
              (r (recover/vars (cdr p))))
          (cond
            ((var? v) (ext/vars v (ext/vars x r)))
            (else (ext/vars x r))))))))

(define ext/vars
  (lambda (x r)
    (cond
      ((memq x r) r)
      (else (cons x r)))))

;;; serious functions

(define oc-prefix
  (lambda (oc)
    (car (oc-rands oc))))

(define reify-prefix-dot (make-parameter #t))

(define (remove-dots p*)
  (cond
   [(reify-prefix-dot) p*]
   [else (map (lambda (p) (list (car p) (cdr p))) p*)]))

(define (sort-ps p*)
  (map (lambda (p)
         (sort-by-lex<=
          (map (lambda (a) (sort-diseq (car a) (cdr a))) p)))
       p*))

(define (sort-diseq u v)
  (cond
  ((char<?
      (string-ref (format "~s" v) 0)
      (string-ref "_" 0))
   (cons u v))
  ((lex<= u v) (cons u v))
  (else (cons v u))))

(define reify-constraintsneq 
  (default-reify 
    '=/=
    '(=/=neq-c)
    (lambda (rands r)
      (let ([p* (walk* (map car rands) r)])
        (map remove-dots (sort-ps p*))))))

(define =/=neq-c
  (lambda (p)
    (lambdam@ (a : s c)
      (let ([p (walk* p s)])
        (cond
         ((unify p s c)
          =>
          (lambdam@ (s/c)
            (let ((p (prefix-s s (car s/c))))
              (cond
               ((null? p) #f)
               (else (bindm a (update-c (build-oc =/=neq-c p)))
                     #;((normalize-store p) a)
                     )))))
         (else a))))))

;; how to read this: 
;; neq-subsume defines an interaction between =/=neq-c constraints
;; if there are two =/=neq-c constraints with prefixes p and p^
;; in the constraint store, if the first subsumes the second, keep
;; only the first constraint.  this is reflexive by default.
(define-constraint-interaction
  neq-subsume
  ((=/=neq-c ,p) (=/=neq-c ,p^))
  #:package (a : s c)
  [(subsumes? p p^ c) ((=/=neq-c p))])

#;
(define normalize-store
  (lambda (p)
    (lambdam@ (a : s c)
      (let ([ncs (filter/rator '=/=neq-c c)])
        (let loop ((ncs ncs) (ncs^ '()))
          (cond
           [(null? ncs)
            (let ([oc (build-oc =/=neq-c p)])
              (bindm a
                (composem
                 (replace-ocs '=/=neq-c ncs^)
                 (update-c oc))))]
           (else
            (let* ((oc (car ncs))
                   (p^ (oc-prefix oc)))
              (cond
               (((subsumes? p^ p) a) a)
               (((subsumes? p p^) a) (loop (cdr ncs) ncs^))
               (else (loop (cdr ncs) (cons oc ncs^))))))))))))

(define subsumes?
  (lambda (p p^ c)
    (cond
     ((unify p p^ c) => 
      (lambda (s/c) (eq? (car s/c) p^)))
     (else #f))))

;;; goals

(define =/=
  (lambda (u v)
    (goal-construct (=/=-c u v))))

(define =/=-c
  (lambda (u v)
    (lambdam@ (a : s c)
      (cond
       ((unify `((,u . ,v)) s c)
        => (lambda (s/c)
             ((=/=neq-c (prefix-s s (car s/c))) a)))
       (else a)))))

(extend-reify-fns 'neq reify-constraintsneq)

