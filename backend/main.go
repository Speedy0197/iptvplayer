package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/flodev/iptvplayer/database"
	"github.com/flodev/iptvplayer/handlers"
	"github.com/flodev/iptvplayer/middleware"
	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
)

func main() {
	dbPath := getEnv("DB_PATH", "/data/iptv.db")
	port := getEnv("PORT", "8080")
	jwtSecret := getEnv("JWT_SECRET", "change-me-in-production")
	smtpPort := getEnv("SMTP_PORT", "587")
	smtpTimeoutSeconds := getEnv("SMTP_TIMEOUT_SECONDS", "15")
	resetTokenTTLMinutes := getEnv("RESET_TOKEN_TTL_MINUTES", "60")
	resetRateWindowSeconds := getEnv("RESET_RATE_WINDOW_SECONDS", "60")
	resetRateLimit := getEnv("RESET_RATE_LIMIT", "5")
	tvLoginTTLMinutes := getEnv("TV_LOGIN_TTL_MINUTES", "10")

	database.Init(dbPath)
	middleware.JWTSecret = []byte(jwtSecret)
	handlers.SMTPHost = getEnv("SMTP_HOST", "")
	handlers.SMTPPort = smtpPort
	handlers.SMTPUsername = getEnv("SMTP_USERNAME", "")
	handlers.SMTPPassword = getEnv("SMTP_PASSWORD", "")
	handlers.SMTPFrom = getEnv("SMTP_FROM", "")
	handlers.SMTPTimeout = parseEnvDurationSeconds(smtpTimeoutSeconds, 15*time.Second)
	handlers.ResetLinkBase = getEnv("RESET_LINK_BASE_URL", "")
	handlers.ResetTokenTTL = parseEnvDurationMinutes(resetTokenTTLMinutes, time.Hour)
	handlers.ResetRateWindow = parseEnvDurationSeconds(resetRateWindowSeconds, time.Minute)
	handlers.ResetRateLimit = parseEnvInt(resetRateLimit, 5)
	handlers.TVLoginTTL = parseEnvDurationMinutes(tvLoginTTLMinutes, 10*time.Minute)

	r := chi.NewRouter()
	r.Use(chimiddleware.Logger)
	r.Use(chimiddleware.Recoverer)
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{"*"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Authorization", "Content-Type"},
		AllowCredentials: false,
	}))

	r.Route("/api/v1", func(r chi.Router) {
		// Public
		r.Post("/auth/register", handlers.Register)
		r.Post("/auth/verify-email", handlers.VerifyEmail)
		r.Post("/auth/resend-verification", handlers.ResendVerification)
		r.Post("/auth/login", handlers.Login)
		r.Post("/auth/tv/start", handlers.StartTVLogin)
		r.Get("/auth/tv/poll", handlers.PollTVLogin)
		r.Post("/auth/tv/approve", handlers.ApproveTVLogin)
		r.Post("/auth/request-reset", handlers.RequestPasswordReset)
		r.Post("/auth/verify-reset", handlers.VerifyResetToken)
		r.Post("/auth/reset-password", handlers.ResetPassword)

		// Protected (token accepted via Authorization header or ?token= query param)
		r.Group(func(r chi.Router) {
			r.Use(middleware.Auth)

			// Playlists
			r.Get("/playlists", handlers.ListPlaylists)
			r.Post("/playlists", handlers.CreatePlaylist)
			r.Put("/playlists/{id}", handlers.UpdatePlaylist)
			r.Delete("/playlists/{id}", handlers.DeletePlaylist)
			r.Get("/playlists/{id}/source", handlers.GetPlaylistSource)

			// Channels & Groups
			r.Get("/playlists/{id}/groups", handlers.ListGroups)
			r.Get("/playlists/{id}/channels", handlers.ListChannels)
			r.Put("/playlists/{id}/channels", handlers.ReplacePlaylistChannels)

			// Favorites
			r.Get("/favorites/channels", handlers.ListFavoriteChannels)
			r.Post("/favorites/channels", handlers.AddFavoriteChannel)
			r.Delete("/favorites/channels", handlers.RemoveFavoriteChannel)
			r.Delete("/favorites/channels/{channel_id}", handlers.RemoveFavoriteChannel)

			r.Get("/favorites/groups", handlers.ListFavoriteGroups)
			r.Post("/favorites/groups", handlers.AddFavoriteGroup)
			r.Delete("/favorites/groups", handlers.RemoveFavoriteGroup)
			r.Delete("/favorites/groups/{playlist_id}/{group_name}", handlers.RemoveFavoriteGroup)
		})
	})

	addr := fmt.Sprintf(":%s", port)
	log.Printf("IPTV backend listening on %s", addr)
	if err := http.ListenAndServe(addr, r); err != nil {
		log.Fatal(err)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func parseEnvInt(value string, fallback int) int {
	v, err := strconv.Atoi(value)
	if err != nil || v <= 0 {
		return fallback
	}
	return v
}

func parseEnvDurationMinutes(value string, fallback time.Duration) time.Duration {
	v, err := strconv.Atoi(value)
	if err != nil || v <= 0 {
		return fallback
	}
	return time.Duration(v) * time.Minute
}

func parseEnvDurationSeconds(value string, fallback time.Duration) time.Duration {
	v, err := strconv.Atoi(value)
	if err != nil || v <= 0 {
		return fallback
	}
	return time.Duration(v) * time.Second
}
